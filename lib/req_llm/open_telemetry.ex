defmodule ReqLLM.OpenTelemetry.Adapter do
  @moduledoc false

  @callback available?() :: boolean()
  @callback start_span(String.t(), map(), keyword()) :: term()
  @callback set_attributes(term(), map(), keyword()) :: :ok
  @callback add_event(term(), atom() | String.t(), map(), keyword()) :: :ok
  @callback set_status(term(), :ok | :error, String.t() | nil, keyword()) :: :ok
  @callback end_span(term(), keyword()) :: :ok
end

defmodule ReqLLM.OpenTelemetry.OTelAdapter do
  @moduledoc false

  @behaviour ReqLLM.OpenTelemetry.Adapter

  @impl true
  def available? do
    Enum.all?(
      [
        {:otel_tracer_provider, :get_tracer, 4},
        {:otel_tracer, :start_span, 3},
        {:otel_span, :set_attributes, 2},
        {:otel_span, :add_event, 3},
        {:otel_span, :set_status, 2},
        {:otel_span, :set_status, 3},
        {:otel_span, :end_span, 1}
      ],
      fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end
    )
  end

  @impl true
  def start_span(name, attributes, _config) do
    call(:otel_tracer, :start_span, [tracer(), name, %{kind: :client, attributes: attributes}])
  end

  @impl true
  def set_attributes(span, attributes, _config) do
    call(:otel_span, :set_attributes, [span, attributes])
    :ok
  end

  @impl true
  def add_event(span, name, attributes, _config) do
    call(:otel_span, :add_event, [span, name, attributes])
    :ok
  end

  @impl true
  def set_status(span, :ok, nil, _config) do
    call(:otel_span, :set_status, [span, :ok])
    :ok
  end

  def set_status(span, :ok, message, _config) do
    call(:otel_span, :set_status, [span, :ok, message])
    :ok
  end

  def set_status(span, :error, nil, _config) do
    call(:otel_span, :set_status, [span, :error])
    :ok
  end

  def set_status(span, :error, message, _config) do
    call(:otel_span, :set_status, [span, :error, message])
    :ok
  end

  @impl true
  def end_span(span, _config) do
    call(:otel_span, :end_span, [span])
    :ok
  end

  defp tracer do
    call(
      :otel_tracer_provider,
      :get_tracer,
      [
        :req_llm,
        application_version(),
        "https://opentelemetry.io/schemas/1.37.0"
      ]
    )
  end

  defp call(module, function, arguments) do
    apply(module, function, arguments)
  end

  defp application_version do
    case Application.spec(:req_llm, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end
end

defmodule ReqLLM.OpenTelemetry do
  @moduledoc """
  Bridges ReqLLM request lifecycle telemetry into OpenTelemetry GenAI client spans.

  This module listens to the existing `[:req_llm, :request, *]` events and emits a
  single client span per model call. The span follows the OpenTelemetry Generative AI
  semantic conventions where ReqLLM has normalized data available, including:

  - `gen_ai.provider.name`
  - `gen_ai.operation.name`
  - `gen_ai.request.model`
  - `gen_ai.output.type`
  - `gen_ai.response.finish_reasons`
  - `gen_ai.usage.*`
  - `error.type`

  Span export remains opt-in at the application level. You still need OpenTelemetry
  dependencies and SDK/exporter configuration in your host app. When the OpenTelemetry
  API modules are not available, `attach/2` returns `{:error, :opentelemetry_unavailable}`.

  For custom tracer integrations that want richer message and tool-call mapping
  without binding ReqLLM to a specific OpenTelemetry SDK, see
  `ReqLLM.Telemetry.OpenTelemetry`.
  """

  alias ReqLLM.MapAccess
  alias ReqLLM.OpenTelemetry.{Attributes, SemConv}

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception]
  ]
  @default_handler_id "req-llm-open-telemetry"
  @span_table :req_llm_open_telemetry_spans
  @default_adapter ReqLLM.OpenTelemetry.OTelAdapter

  @type attach_opt :: {:adapter, module()} | {:handler_id, term()} | {atom(), term()}

  @doc """
  Returns the request lifecycle events used by the bridge.
  """
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc """
  Returns whether the configured OpenTelemetry adapter is available.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    adapter(opts).available?()
  end

  @doc """
  Attaches the OpenTelemetry bridge to ReqLLM request lifecycle events.
  """
  @spec attach(term(), keyword()) :: :ok | {:error, :already_exists | :opentelemetry_unavailable}
  def attach(handler_id \\ @default_handler_id, opts \\ []) do
    if available?(opts) do
      ensure_span_table()

      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        config(handler_id, opts)
      )
    else
      {:error, :opentelemetry_unavailable}
    end
  end

  @doc """
  Detaches the OpenTelemetry bridge and clears any in-flight spans for the handler.
  """
  @spec detach(term()) :: :ok
  def detach(handler_id \\ @default_handler_id) do
    ensure_span_table()
    :ets.match_delete(@span_table, {{handler_id, :_}, :_})
    :telemetry.detach(handler_id)
  end

  @doc """
  Returns the GenAI span name for a ReqLLM request.
  """
  @spec span_name(map()) :: String.t()
  def span_name(metadata) do
    SemConv.span_name(MapAccess.get(metadata, :operation), request_model(metadata) || "unknown")
  end

  @doc false
  @spec handle_event(list(atom()), map(), map(), keyword()) :: :ok
  def handle_event([:req_llm, :request, :start], _measurements, metadata, config) do
    ensure_span_table()

    if request_id = MapAccess.get(metadata, :request_id) do
      attributes = atomize(Attributes.start(metadata))
      span = adapter(config).start_span(span_name(metadata), attributes, config)
      :ets.insert(@span_table, {span_key(config, request_id), span})
    end

    :ok
  end

  def handle_event([:req_llm, :request, :stop], _measurements, metadata, config) do
    with request_id when is_binary(request_id) <- MapAccess.get(metadata, :request_id),
         {:ok, span} <- take_span(config, request_id) do
      adapter(config).set_attributes(span, atomize(Attributes.terminal(metadata)), config)

      case Attributes.error_status(metadata) do
        nil ->
          :ok

        {_error_type, message} ->
          adapter(config).set_status(span, :error, message, config)
      end

      adapter(config).end_span(span, config)
    end

    :ok
  end

  def handle_event([:req_llm, :request, :exception], _measurements, metadata, config) do
    with request_id when is_binary(request_id) <- MapAccess.get(metadata, :request_id),
         {:ok, span} <- take_span(config, request_id) do
      adapter(config).set_attributes(span, atomize(Attributes.exception(metadata)), config)

      adapter(config).add_event(
        span,
        :exception,
        atomize(Attributes.exception_event(metadata)),
        config
      )

      adapter(config).set_status(
        span,
        :error,
        exception_message(MapAccess.get(metadata, :error)),
        config
      )

      adapter(config).end_span(span, config)
    end

    :ok
  end

  defp config(handler_id, opts) do
    opts
    |> Keyword.put_new(:adapter, @default_adapter)
    |> Keyword.put(:handler_id, handler_id)
  end

  defp adapter(opts), do: Keyword.get(opts, :adapter, @default_adapter)

  defp ensure_span_table do
    case :ets.whereis(@span_table) do
      :undefined ->
        :ets.new(@span_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ ->
        @span_table
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp span_key(config, request_id) do
    {Keyword.get(config, :handler_id, @default_handler_id), request_id}
  end

  defp take_span(config, request_id) do
    key = span_key(config, request_id)

    case :ets.lookup(@span_table, key) do
      [{^key, span}] ->
        :ets.delete(@span_table, key)
        {:ok, span}

      [] ->
        :error
    end
  end

  defp atomize(map) do
    Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp request_model(%{model: %LLMDB.Model{id: id}}), do: id

  defp request_model(%{model: model}) when is_map(model),
    do: Map.get(model, :id)

  defp request_model(_), do: nil

  defp exception_message(nil), do: nil
  defp exception_message(%{__struct__: _} = error), do: Exception.message(error)
  defp exception_message(error), do: inspect(error)
end
