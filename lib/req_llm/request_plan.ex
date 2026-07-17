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

  @type surface ::
          :openai_responses
          | :openai_chat_completions
          | :anthropic_messages
  @type transport :: :req | :finch | :websocket

  @type t :: %__MODULE__{
          model: LLMDB.Model.t(),
          operation: :chat | :object,
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
         normalized_opts <- normalize_options(merged_opts),
         {:ok, model} <- resolve_model(model_input),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
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
         warnings: input_warnings ++ surface_warnings ++ transport_warnings
       }}
    end
  end

  def build(_model_input, _operation, opts) do
    invalid_parameter("options must be a keyword list, got: #{inspect(opts)}")
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
      resolve_openai_surface(model)
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
