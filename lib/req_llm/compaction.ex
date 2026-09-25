defmodule ReqLLM.Compaction do
  @moduledoc """
  Context compaction for the OpenAI Responses API (OpenAI and Azure OpenAI).

  Compaction asks the service to fold a long conversation into one or more
  opaque `compaction` items that carry the essential prior state in far fewer
  tokens. Those items come back as `:provider_block` content parts on the
  assistant message of the returned response and are replayed verbatim by the
  Responses encoder on the next request.

  ## Usage

      {:ok, first} = ReqLLM.generate_text(model, "Draft a landing page.")

      {:ok, compacted} = ReqLLM.compact_context(model, first.context)

      next = ReqLLM.Context.append(compacted.context, ReqLLM.Context.user("Add a booking form."))
      {:ok, follow_up} = ReqLLM.generate_text(model, next)

  `compacted.context` holds the complete returned window in one message. Its
  `metadata.responses_replay` preserves all API items, including retained user
  messages, assistant messages, and tool items, in their original order. Do not
  prune this window: the next request must replay it as returned by the service.
  Append the next user message to continue. The service can also compact a
  stored response instead of a replayed context:

      {:ok, compacted} = ReqLLM.compact_context(model, nil, previous_response_id: first.id)

  Server-side compaction on ordinary requests is enabled with the
  `context_management` provider option; the resulting `compaction` items land
  on the response message the same way and replay automatically.

  The compacted message keeps the compaction response id under
  `metadata.compaction_response_id` rather than `metadata.response_id`, so the
  next turn replays the compaction items instead of chaining through
  `previous_response_id`.
  """

  alias LLMDB.Model
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  @compaction_block_type "compaction"

  @base_schema NimbleOptions.new!(
                 previous_response_id: [
                   type: :string,
                   doc: "Stored response to compact instead of replaying a context"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 receive_timeout: [
                   type: :timeout,
                   doc: "Timeout for the compaction request in milliseconds"
                 ],
                 base_url: [type: :string, doc: "Override the provider base URL"],
                 api_key: [type: :string, doc: "Override the provider API key"],
                 deployment: [type: :string, doc: "Azure deployment name"]
               )

  @doc "Returns the option schema used for tuple-model defaults."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Compacts a conversation through `POST /responses/compact`.

  `messages` is anything `ReqLLM.Context.normalize/2` accepts, or `nil` when
  `previous_response_id:` names the stored response to compact; passing both
  is an error. Returns a `ReqLLM.Response` whose `context` contains only the
  returned window (see `compacted_message/1`).
  """
  @spec compact_context(
          ReqLLM.model_input(),
          Context.t() | Message.t() | [term()] | String.t() | nil,
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def compact_context(model_spec, messages, opts \\ [])

  def compact_context(model_spec, messages, opts) when is_list(opts) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :compact, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, %Model{} = model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :compact,
             model,
             opts
           ),
         {:ok, context} <- Context.normalize(messages || [], opts),
         :ok <- validate_input(context, opts),
         {:ok, request} <-
           provider_module.prepare_request(
             :compact,
             model,
             context,
             Keyword.put(opts, :operation, :compact)
           ),
         {:ok, response} <- run_request(request, deadline) do
      {:ok, finalize(response)}
    end
  end

  def compact_context(_model_spec, _messages, other) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "opts: expected a keyword list, got: #{inspect(other)}"
     )}
  end

  @doc """
  Same as `compact_context/3` but raises on error.
  """
  @spec compact_context!(
          ReqLLM.model_input(),
          Context.t() | Message.t() | [term()] | String.t() | nil,
          keyword()
        ) :: Response.t() | no_return()
  def compact_context!(model_spec, messages, opts \\ []) do
    case compact_context(model_spec, messages, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Drops every message before the most recent one carrying a compaction item.

  The compaction item carries the context needed to continue, so earlier
  history only adds request size. Returns the context unchanged when it holds
  no compaction item.
  """
  @spec trim(Context.t()) :: Context.t()
  def trim(%Context{messages: messages} = context) do
    messages
    |> Enum.reverse()
    |> Enum.find_index(&compaction_message?/1)
    |> case do
      nil -> context
      from_end -> %{context | messages: Enum.drop(messages, length(messages) - from_end - 1)}
    end
  end

  @doc "Whether a message carries at least one compaction item."
  @spec compaction_message?(Message.t()) :: boolean()
  def compaction_message?(%Message{content: content}) when is_list(content) do
    Enum.any?(content, &compaction_part?/1)
  end

  def compaction_message?(_message), do: false

  @doc "Whether a content part is a replayable compaction item."
  @spec compaction_part?(ContentPart.t()) :: boolean()
  def compaction_part?(%ContentPart{type: :provider_block, metadata: metadata}) do
    block_type = Map.get(metadata, :block_type) || Map.get(metadata, "block_type")
    block_type == @compaction_block_type
  end

  def compaction_part?(_part), do: false

  defp validate_input(%Context{messages: []}, opts) do
    if previous_response_id(opts) do
      :ok
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "messages: compact_context needs messages or a previous_response_id"
       )}
    end
  end

  defp validate_input(%Context{}, opts) do
    if previous_response_id(opts) do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "messages: pass either messages or a previous_response_id, not both"
       )}
    else
      :ok
    end
  end

  defp previous_response_id(opts) do
    Keyword.get(opts, :previous_response_id) ||
      provider_option(Keyword.get(opts, :provider_options, []), :previous_response_id)
  end

  defp provider_option(provider_options, key) when is_list(provider_options) do
    if Keyword.keyword?(provider_options), do: Keyword.get(provider_options, key), else: nil
  end

  defp provider_option(provider_options, key) when is_map(provider_options) do
    Map.get(provider_options, key) || Map.get(provider_options, Atom.to_string(key))
  end

  defp provider_option(_provider_options, _key), do: nil

  defp run_request(request, deadline) do
    case ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, %Req.Response{status: status, body: %Response{} = response}}
      when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: compaction request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize(%Response{message: %Message{} = message} = response) do
    message = compacted_message(message)
    %{response | message: message, context: Context.new([message])}
  end

  defp finalize(%Response{} = response), do: response

  @doc """
  Prepares a compaction response message for replay without pruning its items.

  The complete output window in `metadata.responses_replay` is authoritative.
  Retained messages and tool items must stay in their original order. The
  compaction response ID cannot be used as a normal `previous_response_id`.
  """
  @spec compacted_message(Message.t()) :: Message.t()
  def compacted_message(%Message{} = message) do
    %{message | metadata: relabel_response_id(message.metadata)}
  end

  defp relabel_response_id(metadata) when is_map(metadata) do
    case Map.pop(metadata, :response_id) do
      {nil, metadata} -> metadata
      {id, metadata} -> Map.put(metadata, :compaction_response_id, id)
    end
  end

  defp relabel_response_id(metadata), do: metadata
end
