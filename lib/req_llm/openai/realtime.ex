defmodule ReqLLM.OpenAI.Realtime do
  @moduledoc """
  Experimental low-level Realtime WebSocket client for OpenAI.

  This module exposes a small session-oriented API for Realtime workflows that
  do not map cleanly onto `ReqLLM.stream_text/3`. It is intentionally low-level:
  you connect a session, send JSON events, receive JSON events, and close the
  socket when you are done.

  `next_event/2` remains the raw provider-event API. Use
  `next_projected_event/3` or `project_event/2` for an additive view that keeps
  the sanitized native event alongside any exact `ReqLLM.StreamEvent` overlap.
  Session, transport, audio, MCP, rate-limit, and other provider-native events
  are not forced into portable event types.
  """

  alias ReqLLM.OpenAI.Realtime.Event
  alias ReqLLM.OpenAI.Realtime.EventProjector
  alias ReqLLM.Streaming.WebSocketSession

  @projection_schema NimbleOptions.new!(
                       payloads: [
                         type: {:in, [:none, :raw]},
                         default: :none,
                         doc: "Include raw text, audio transcript, tool, and error payloads"
                       ],
                       model: [
                         type: {:struct, LLMDB.Model},
                         doc: "Resolved model used to project response.created as :start"
                       ]
                     )

  defmodule Session do
    @moduledoc """
    An experimental OpenAI Realtime WebSocket session.
    """

    @enforce_keys [:pid, :model]
    defstruct [:pid, :model]

    @type t :: %__MODULE__{
            pid: pid(),
            model: LLMDB.Model.t()
          }
  end

  @default_connect_timeout 10_000

  @spec connect(ReqLLM.model_input() | String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def connect(model_spec \\ "gpt-realtime", opts \\ []) do
    with {:ok, model} <- normalize_model(model_spec),
         url <- ReqLLM.Providers.OpenAI.WebSocket.realtime_url(model, opts),
         headers <- ReqLLM.Providers.OpenAI.WebSocket.headers(model, opts),
         {:ok, pid} <- WebSocketSession.start_link(url, headers: headers),
         :ok <-
           WebSocketSession.await_connected(
             pid,
             Keyword.get(opts, :connect_timeout, @default_connect_timeout)
           ) do
      {:ok, %Session{pid: pid, model: model}}
    end
  end

  @spec send_event(Session.t(), map()) :: :ok | {:error, term()}
  def send_event(%Session{pid: pid}, event) when is_map(event) do
    WebSocketSession.send_json(pid, event)
  end

  @spec next_event(Session.t(), non_neg_integer()) :: {:ok, map()} | :halt | {:error, term()}
  def next_event(%Session{pid: pid}, timeout \\ 30_000) do
    with {:ok, message} <- WebSocketSession.next_message(pid, timeout) do
      Jason.decode(message)
    end
  end

  @doc """
  Receives one raw event and returns its provider-native and exact portable views.

  Sensitive text, audio transcript, tool, and error payloads are redacted by
  default. Pass `payloads: :raw` only when the consumer is authorized to retain
  model and tool content. This function does not loop, reconnect, execute tools,
  or continue a response.
  """
  @spec next_projected_event(Session.t()) :: {:ok, Event.t()} | :halt | {:error, term()}
  def next_projected_event(%Session{} = session), do: next_projected_event(session, 30_000, [])

  @spec next_projected_event(Session.t(), non_neg_integer() | keyword()) ::
          {:ok, Event.t()} | :halt | {:error, term()}
  def next_projected_event(%Session{} = session, opts) when is_list(opts),
    do: next_projected_event(session, 30_000, opts)

  def next_projected_event(%Session{} = session, timeout)
      when is_integer(timeout) and timeout >= 0,
      do: next_projected_event(session, timeout, [])

  @spec next_projected_event(Session.t(), non_neg_integer(), keyword()) ::
          {:ok, Event.t()} | :halt | {:error, term()}
  def next_projected_event(%Session{} = session, timeout, opts)
      when is_integer(timeout) and timeout >= 0 and is_list(opts) do
    with {:ok, event} <- next_event(session, timeout) do
      {:ok, project_event(event, Keyword.put(opts, :model, session.model))}
    end
  end

  @doc """
  Projects one already-decoded OpenAI Realtime server event.

  The returned `ReqLLM.OpenAI.Realtime.Event` always retains a native view.
  `stream_events` is empty when no exact provider-neutral meaning exists.
  Supplying the resolved `:model` allows `response.created` to project to the
  canonical `:start` event.
  """
  @spec project_event(map(), keyword()) :: Event.t()
  def project_event(event, opts \\ []) when is_map(event) and is_list(opts) do
    opts = NimbleOptions.validate!(opts, @projection_schema)
    EventProjector.project(event, opts)
  end

  @spec session_update(Session.t(), map()) :: :ok | {:error, term()}
  def session_update(%Session{} = session, session_payload) when is_map(session_payload) do
    send_event(session, %{
      "type" => "session.update",
      "session" => session_payload
    })
  end

  @spec response_create(Session.t(), map()) :: :ok | {:error, term()}
  def response_create(%Session{} = session, response_payload \\ %{})
      when is_map(response_payload) do
    send_event(session, %{
      "type" => "response.create",
      "response" => response_payload
    })
  end

  @spec close(Session.t()) :: :ok
  def close(%Session{pid: pid}) do
    WebSocketSession.close(pid)
  end

  defp normalize_model(%LLMDB.Model{provider: :openai} = model), do: {:ok, model}

  defp normalize_model(%LLMDB.Model{provider: provider}) do
    {:error, ReqLLM.Error.Invalid.Provider.exception(provider: provider)}
  end

  defp normalize_model(model_spec) when is_binary(model_spec) do
    if String.contains?(model_spec, ":") do
      ReqLLM.model(model_spec)
    else
      ReqLLM.model(%{provider: :openai, id: model_spec})
    end
  end

  defp normalize_model(model_spec), do: ReqLLM.model(model_spec)
end
