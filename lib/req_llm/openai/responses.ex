defmodule ReqLLM.OpenAI.Responses do
  @moduledoc """
  Experimental OpenAI Responses helpers and persistent WebSocket sessions.

  Use `with_reasoning_effort/2` with a user message to change Astra reasoning
  effort within a conversation. The Responses encoder places the update just
  before that message. Keep the request-level `:reasoning_effort` unchanged.

  A session exposes raw provider events across response boundaries. The caller
  tracks response IDs, accepted steer IDs, and pending tool calls. An accepted
  steer is queued; it does not confirm that the steer was applied. Continue to
  read events after `response.completed` or `response.incomplete` to receive the
  automatic successor response.

  If steering requires tool results, send a new `response_create/2` with those
  results and the pending event's response ID on the same session. Include the
  instructions and tools again. Do not repeat the steer input. The client does
  not execute tools, reconnect, or retry events after a connection failure.
  """

  alias ReqLLM.Message
  alias ReqLLM.Providers.OpenAI.Astra
  alias ReqLLM.Providers.OpenAI.WebSocket
  alias ReqLLM.Streaming.WebSocketSession

  defmodule Session do
    @moduledoc "An experimental OpenAI Responses WebSocket session."
    @enforce_keys [:pid, :model]
    defstruct [:pid, :model]

    @type t :: %__MODULE__{pid: pid(), model: LLMDB.Model.t()}
  end

  @doc """
  Adds a reasoning update to an Astra user message.

  Accepts low, medium, high, xhigh, or max as an atom or string. Raises
  `ReqLLM.Error.Invalid.Parameter` for other values or message roles.
  The message metadata retains the update's position when the context grows.
  This feature requires standard single-agent mode without automatic context
  compaction or truncation. After explicit compaction, add a fresh update.
  """
  @spec with_reasoning_effort(Message.t(), atom() | String.t()) :: Message.t()
  def with_reasoning_effort(%Message{role: :user, content: [_ | _]} = message, effort) do
    effort = Astra.validate_effort!(effort)
    %{message | metadata: Map.put(message.metadata, :openai_reasoning_effort, effort)}
  end

  def with_reasoning_effort(_message, _effort) do
    Astra.invalid!("A reasoning update requires a nonempty user message")
  end

  @doc "Connects to the Responses WebSocket endpoint and waits for the connection."
  @spec connect(ReqLLM.model_input(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def connect(model_spec, opts \\ []) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- validate_provider(model),
         {:ok, pid} <- WebSocket.start_responses_session(model, opts) do
      case WebSocketSession.await_connected(pid, Keyword.get(opts, :connect_timeout, 10_000)) do
        :ok ->
          {:ok, %Session{pid: pid, model: model}}

        {:error, _} = error ->
          WebSocketSession.close(pid)
          error
      end
    end
  end

  @doc """
  Starts or continues a response using a native Responses request map.

  Map keys must be strings. The session supplies `model` and `type`.
  `stream` and `background` are not valid WebSocket request fields.
  This low-level API accepts provider options, not ReqLLM generation options.
  """
  @spec response_create(Session.t(), map()) :: :ok | {:error, term()}
  def response_create(%Session{} = session, payload) when is_map(payload) do
    model_name = session.model.provider_model_id || session.model.id
    validate_create!(payload, model_name)

    event = payload |> Map.put("model", model_name) |> Map.put("type", "response.create")
    WebSocketSession.send_json(session.pid, event)
  rescue
    error in ReqLLM.Error.Invalid.Parameter -> {:error, error}
  end

  @doc """
  Queues user input for an active Astra response.

  Wait for `response.created` before sending its ID. Input can be a nonempty
  string or a list of native user messages. Read all `response.steer.*` events
  with `next_event/2`; a successful send alone does not mean acceptance.
  """
  @spec steer(Session.t(), String.t(), String.t() | [map()]) :: :ok | {:error, term()}
  def steer(%Session{} = session, previous_response_id, input) do
    Astra.require_astra!(session.model.id, "Steering")

    unless is_binary(previous_response_id) and previous_response_id != "" do
      Astra.invalid!("Steering requires the active response ID")
    end

    unless valid_steer_input?(input), do: Astra.invalid!("Steering requires nonempty user input")

    WebSocketSession.send_json(session.pid, %{
      "type" => "response.steer",
      "previous_response_id" => previous_response_id,
      "input" => input
    })
  rescue
    error in ReqLLM.Error.Invalid.Parameter -> {:error, error}
  end

  @doc "Receives one raw event. Response completion does not close the session."
  @spec next_event(Session.t(), timeout()) :: {:ok, map()} | :halt | {:error, term()}
  def next_event(%Session{pid: pid}, timeout \\ 30_000) do
    with {:ok, message} <- WebSocketSession.next_message(pid, timeout) do
      Jason.decode(message)
    end
  end

  @doc "Closes the session."
  @spec close(Session.t()) :: :ok
  def close(%Session{pid: pid}), do: WebSocketSession.close(pid)

  defp validate_provider(%LLMDB.Model{provider: :openai}), do: :ok

  defp validate_provider(%LLMDB.Model{provider: provider}) do
    {:error, ReqLLM.Error.Invalid.Provider.exception(provider: provider)}
  end

  defp validate_create!(payload, model_name) do
    unless Enum.all?(Map.keys(payload), &is_binary/1) do
      Astra.invalid!("Responses request keys must be strings")
    end

    for key <- ["stream", "background", "response", "type"] do
      if Map.has_key?(payload, key),
        do: Astra.invalid!("WebSocket response.create does not accept #{key}")
    end

    if Map.has_key?(payload, "model") and payload["model"] != model_name do
      Astra.invalid!("The response model must match the session model")
    end

    Astra.validate_body!(payload, model_name)
  end

  defp valid_steer_input?(input) when is_binary(input), do: String.trim(input) != ""

  defp valid_steer_input?([_ | _] = input) do
    Enum.all?(input, fn
      %{"role" => "user", "content" => content} = message ->
        Map.get(message, "type", "message") == "message" and valid_user_content?(content)

      _ ->
        false
    end)
  end

  defp valid_steer_input?(_input), do: false

  defp valid_user_content?(content) when is_binary(content), do: String.trim(content) != ""
  defp valid_user_content?([_ | _] = content), do: Enum.all?(content, &is_map/1)
  defp valid_user_content?(_content), do: false
end
