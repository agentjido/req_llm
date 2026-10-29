defmodule ReqLLM.RequestPlan do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter

  @enforce_keys [
    :model,
    :operation,
    :provider,
    :surface,
    :transport,
    :options,
    :provider_module,
    :api_module
  ]
  defstruct @enforce_keys ++ [warnings: []]

  @type operation :: atom()

  @operations [
    :chat,
    :object,
    :embedding,
    :image,
    :speech,
    :transcription,
    :rerank,
    :ocr,
    :video,
    :video_query,
    :video_upload,
    :video_retrieve,
    :compact,
    :evaluate
  ]

  @type surface ::
          :provider
          | :openai_responses
          | :openai_chat_completions
          | :anthropic_messages
  @type transport :: :req | :finch | :websocket | :in_process

  @type t :: %__MODULE__{
          model: LLMDB.Model.t(),
          operation: operation(),
          provider: atom(),
          surface: surface(),
          transport: transport(),
          options: keyword(),
          provider_module: module(),
          api_module: module(),
          warnings: [binary()]
        }

  @doc false
  @spec build(ReqLLM.model_input(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(model_input, operation, opts \\ [])

  def build(model_input, operation, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_operation(operation),
         {merged_opts, input_warnings} <-
           ReqLLM.ModelInput.merge_tuple_defaults_with_warnings(model_input, operation, opts),
         {:ok, model} <- resolve_model(model_input),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, namespaced_opts, namespace_warnings} <-
           ReqLLM.Provider.Options.Namespace.normalize(
             provider_module,
             operation,
             model,
             merged_opts
           ),
         {:ok, flat_opts} <-
           ReqLLM.Provider.Options.normalize_flat_provider_options(
             provider_module,
             namespaced_opts
           ),
         normalized_opts <- normalize_options(flat_opts),
         {:ok, surface, api_module, surface_warnings} <-
           resolve_surface(model, provider_module),
         {:ok, transport, transport_warnings} <-
           resolve_transport(surface, normalized_opts) do
      {:ok,
       %__MODULE__{
         model: model,
         operation: operation,
         provider: model.provider,
         surface: surface,
         transport: transport,
         options: canonicalize(normalized_opts),
         provider_module: provider_module,
         api_module: api_module,
         warnings: input_warnings ++ namespace_warnings ++ surface_warnings ++ transport_warnings
       }}
    end
  end

  def build(_model_input, _operation, opts) do
    invalid_parameter("options must be a keyword list, got: #{inspect(opts)}")
  end

  @doc """
  Describes an operation after its boundary has resolved the model, selected the
  provider module, and merged its options.

  This constructor does not resolve or enrich the model, look up a provider,
  process options, or call transport callbacks. The caller supplies the selected
  transport using plan values: `:req` for buffered requests, `:finch` for HTTP
  streams, `:websocket`, or `:in_process`. Options retain their order and values.

  OpenAI and Anthropic chat/object operations retain their existing surface
  resolution and WebSocket restrictions. Other routes use `:provider` with the
  selected provider module as `api_module`; their current callbacks still own
  endpoint and payload selection.
  Single and batch embeddings share `:embedding`. Video submission, polling,
  upload and retrieval use their existing distinct provider operation atoms.

  This is a description, not a capability check or an execution entry point.
  `build/3` remains the compatibility boundary for existing chat/object callers
  and the public diagnostic.
  """
  @spec from_resolved(LLMDB.Model.t(), operation(), module(), keyword(), transport()) ::
          {:ok, t()} | {:error, term()}
  def from_resolved(%LLMDB.Model{} = model, operation, provider_module, opts, transport) do
    with :ok <- validate_options(opts),
         :ok <- validate_resolved_operation(operation),
         :ok <- validate_resolved_transport(transport),
         {:ok, surface, api_module, warnings} <-
           resolve_operation_surface(model, operation, provider_module),
         :ok <- validate_resolved_surface_transport(surface, transport) do
      {:ok,
       %__MODULE__{
         model: model,
         operation: operation,
         provider: model.provider,
         surface: surface,
         transport: transport,
         options: opts,
         provider_module: provider_module,
         api_module: api_module,
         warnings: warnings
       }}
    end
  end

  @doc false
  @spec from_stream(LLMDB.Model.t(), operation(), module(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_stream(%LLMDB.Model{} = model, operation, provider_module, opts) do
    with {:ok, transport} <-
           normalize_stream_transport(
             ReqLLM.Provider.Adapter.stream_transport(provider_module, model, opts)
           ) do
      from_resolved_stream(model, operation, provider_module, opts, transport)
    end
  end

  @doc false
  @spec from_resolved_stream(LLMDB.Model.t(), operation(), module(), keyword(), transport()) ::
          {:ok, t()} | {:error, term()}
  def from_resolved_stream(%LLMDB.Model{} = model, operation, provider_module, opts, transport) do
    with :ok <- validate_options(opts),
         :ok <- validate_resolved_transport(transport) do
      {surface, api_module, warnings} =
        stream_surface(model, operation, provider_module)

      {:ok,
       %__MODULE__{
         model: model,
         operation: operation,
         provider: model.provider,
         surface: surface,
         transport: transport,
         options: opts,
         provider_module: provider_module,
         api_module: api_module,
         warnings: warnings
       }}
    end
  end

  @doc false
  @spec openai_surface(LLMDB.Model.t()) ::
          {:ok, :openai_responses | :openai_chat_completions, module(), [binary()]}
          | {:error, term()}
  def openai_surface(%LLMDB.Model{provider: :openai} = model) do
    resolve_openai_surface(model)
  end

  def openai_surface(%LLMDB.Model{provider: provider}) do
    invalid_parameter("OpenAI surface resolution does not support provider #{inspect(provider)}")
  end

  defp validate_resolved_operation(operation) when operation in @operations, do: :ok

  defp validate_resolved_operation(operation),
    do: invalid_parameter("unsupported request-plan operation: #{inspect(operation)}")

  defp validate_resolved_transport(transport)
       when transport in [:req, :finch, :websocket, :in_process],
       do: :ok

  defp validate_resolved_transport(transport),
    do: invalid_parameter("unsupported request-plan transport: #{inspect(transport)}")

  defp normalize_stream_transport(:http), do: {:ok, :finch}
  defp normalize_stream_transport(:websocket), do: {:ok, :websocket}
  defp normalize_stream_transport(:in_process), do: {:ok, :in_process}

  defp validate_resolved_surface_transport(:provider, _transport), do: :ok

  defp validate_resolved_surface_transport(surface, transport),
    do: validate_transport_surface(surface, true, transport)

  defp resolve_operation_surface(model, operation, provider_module)
       when operation in [:chat, :object] and
              provider_module in [ReqLLM.Providers.OpenAI, ReqLLM.Providers.Anthropic] do
    resolve_surface(model, provider_module)
  end

  defp resolve_operation_surface(_model, _operation, provider_module),
    do: {:ok, :provider, provider_module, []}

  defp stream_surface(model, operation, provider_module) do
    case resolve_operation_surface(model, operation, provider_module) do
      {:ok, surface, api_module, warnings} -> {surface, api_module, warnings}
      {:error, _reason} -> {:provider, provider_module, []}
    end
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      invalid_parameter("options must be a keyword list, got: #{inspect(opts)}")
    end
  end

  defp validate_operation(operation) when operation in [:chat, :object], do: :ok

  defp validate_operation(operation) do
    invalid_parameter(
      "request planning supports only :chat and :object operations, got: #{inspect(operation)}"
    )
  end

  defp resolve_model(model_input) do
    with {:ok, %LLMDB.Model{} = model} <- ReqLLM.model(model_input) do
      ReqLLM.model(model)
    end
  end

  defp resolve_surface(%LLMDB.Model{provider: :openai} = model, provider_module) do
    if provider_module == ReqLLM.Providers.OpenAI do
      openai_surface(model)
    else
      invalid_parameter(
        "provider :openai resolves to unsupported request-plan module #{inspect(provider_module)}"
      )
    end
  end

  defp resolve_surface(%LLMDB.Model{provider: :anthropic} = model, provider_module) do
    if provider_module == ReqLLM.Providers.Anthropic do
      case wire_protocol(model) do
        nil ->
          {:ok, :anthropic_messages, ReqLLM.Providers.Anthropic, []}

        "anthropic_messages" ->
          {:ok, :anthropic_messages, ReqLLM.Providers.Anthropic, []}

        protocol ->
          invalid_surface(model, protocol)
      end
    else
      invalid_parameter(
        "provider :anthropic resolves to unsupported request-plan module #{inspect(provider_module)}"
      )
    end
  end

  defp resolve_surface(%LLMDB.Model{provider: provider}, _provider_module) do
    invalid_parameter(
      "request planning does not define an execution surface for provider #{inspect(provider)}"
    )
  end

  defp resolve_openai_surface(model) do
    case wire_protocol(model) do
      "openai_responses" ->
        {:ok, :openai_responses, ReqLLM.Providers.OpenAI.ResponsesAPI, []}

      "openai_chat" ->
        {:ok, :openai_chat_completions, ReqLLM.Providers.OpenAI.ChatAPI, []}

      nil ->
        infer_openai_surface(model)

      protocol ->
        invalid_surface(model, protocol)
    end
  end

  defp infer_openai_surface(model) do
    model_id = model.provider_model_id || model.id

    if ReqLLM.Providers.OpenAI.AdapterHelpers.responses_model?(model_id) do
      {:ok, :openai_responses, ReqLLM.Providers.OpenAI.ResponsesAPI,
       ["Inferred OpenAI Responses because model wire metadata is absent"]}
    else
      {:ok, :openai_chat_completions, ReqLLM.Providers.OpenAI.ChatAPI,
       ["Defaulted to OpenAI Chat Completions because model wire metadata is absent"]}
    end
  end

  defp invalid_surface(model, protocol) do
    invalid_parameter(
      "wire protocol #{inspect(protocol)} is invalid for provider #{inspect(model.provider)}"
    )
  end

  defp resolve_transport(surface, opts) do
    with {:ok, stream?} <- stream?(opts),
         {:ok, requested, explicit?} <- requested_stream_transport(opts),
         :ok <- validate_transport_surface(surface, stream?, requested) do
      transport = selected_transport(stream?, requested)
      warnings = transport_warnings(stream?, explicit?)
      {:ok, transport, warnings}
    end
  end

  defp stream?(opts) do
    case Keyword.get(opts, :stream, false) do
      value when is_boolean(value) -> {:ok, value}
      value -> invalid_parameter(":stream must be a boolean, got: #{inspect(value)}")
    end
  end

  defp requested_stream_transport(opts) do
    with :ok <- validate_internal_stream_transport(opts) do
      case provider_option(opts, :openai_stream_transport, :none) do
        :none -> {:ok, :http, false}
        value when value in [:sse, "sse"] -> {:ok, :http, true}
        value when value in [:websocket, "websocket"] -> {:ok, :websocket, true}
        value -> invalid_parameter("unsupported OpenAI stream transport: #{inspect(value)}")
      end
    end
  end

  defp validate_internal_stream_transport(opts) do
    case Keyword.fetch(opts, :stream_transport) do
      :error ->
        :ok

      {:ok, value} when value in [:http, :websocket] ->
        :ok

      {:ok, value} ->
        invalid_parameter("unsupported internal stream transport: #{inspect(value)}")
    end
  end

  defp provider_option(opts, key, default) do
    case Keyword.get(opts, :provider_options, []) do
      provider_opts when is_list(provider_opts) -> Keyword.get(provider_opts, key, default)
      provider_opts when is_map(provider_opts) -> Map.get(provider_opts, key, default)
      _provider_opts -> default
    end
  end

  defp validate_transport_surface(:openai_responses, true, :websocket), do: :ok

  defp validate_transport_surface(surface, true, :websocket) do
    invalid_parameter("WebSocket transport is not supported by #{surface_name(surface)}")
  end

  defp validate_transport_surface(_surface, _stream?, _transport), do: :ok

  defp selected_transport(false, _requested), do: :req
  defp selected_transport(true, :http), do: :finch
  defp selected_transport(true, :websocket), do: :websocket

  defp transport_warnings(false, true),
    do: ["Ignored streaming transport selection for a non-streaming request plan"]

  defp transport_warnings(_stream?, _explicit?), do: []

  defp surface_name(:openai_chat_completions), do: "OpenAI Chat Completions"
  defp surface_name(:anthropic_messages), do: "Anthropic Messages"

  defp normalize_options(opts) do
    case Keyword.pop(opts, :stream?) do
      {nil, rest} -> rest
      {value, rest} -> Keyword.put(rest, :stream, value)
    end
  end

  defp canonicalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {key, canonicalize(item)} end)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    else
      Enum.map(value, &canonicalize/1)
    end
  end

  defp canonicalize(%_{} = struct), do: struct

  defp canonicalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, canonicalize(item)} end)
  end

  defp canonicalize(value), do: value

  defp wire_protocol(%LLMDB.Model{extra: extra}) when is_map(extra) do
    wire = Map.get(extra, :wire) || Map.get(extra, "wire")

    case wire do
      wire when is_map(wire) -> Map.get(wire, :protocol) || Map.get(wire, "protocol")
      _wire -> nil
    end
  end

  defp wire_protocol(%LLMDB.Model{}), do: nil

  defp invalid_parameter(message) do
    {:error, Parameter.exception(parameter: message)}
  end
end
