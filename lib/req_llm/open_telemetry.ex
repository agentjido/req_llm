defmodule ReqLLM.OpenTelemetry.Adapter do
  @moduledoc """
  Behaviour the OpenTelemetry bridge uses to talk to a tracer.

  `ReqLLM.OpenTelemetry` ships `ReqLLM.OpenTelemetry.OTelAdapter` as the
  default implementation, which calls the standard `:otel_tracer` and
  `:otel_span` API. Implement this behaviour to swap in a different tracer,
  inject extra attributes on every span (e.g. caller-context like
  `langfuse.user.id`), or run the bridge in test mode without an OpenTelemetry
  SDK.

  Pass your module via `:adapter`:

      ReqLLM.OpenTelemetry.attach("req-llm-otel", adapter: MyApp.ReqLLMAdapter)

  ## Required callbacks

  `available?/0`, `start_span/3`, `set_attributes/3`, `add_event/4`,
  `set_status/4`, `end_span/2`.

  ## Optional callbacks (metrics)

  `metrics_available?/0`, `record_histogram/2`. The bridge only invokes
  these when both `available?/0` and `metrics_available?/0` return `true`.

  ## Optional callbacks (child spans for server-side tool execution)

  `start_child_span/5`, `end_span_at/3`. The bridge invokes these to emit
  `gen_ai.execute_tool` child spans for server-side builtin tool calls
  (e.g. `web_search_call` on the OpenAI Responses API). Adapters that
  don't implement them get a fallback: the bridge calls `start_span/3` +
  `end_span/2` instead, which records the same data but loses the
  parent-child relationship (the sub-spans appear as siblings).

  ## Example — inject caller-context on every ReqLLM span

  The cleanest way to wrap the default adapter is to delegate everything and
  override just `start_span/3` to merge in extra attributes:

      defmodule MyApp.ReqLLMAdapter do
        @behaviour ReqLLM.OpenTelemetry.Adapter

        defdelegate available?(), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate metrics_available?(), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate set_attributes(s, a, c), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate add_event(s, n, a, c), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate set_status(s, k, m, c), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate end_span(s, c), to: ReqLLM.OpenTelemetry.OTelAdapter
        defdelegate record_histogram(r, c), to: ReqLLM.OpenTelemetry.OTelAdapter

        def start_span(name, attrs, config) do
          extras = %{"langfuse.user.id" => Process.get(:current_user_id)}
          ReqLLM.OpenTelemetry.OTelAdapter.start_span(name, Map.merge(attrs, extras), config)
        end
      end

      ReqLLM.OpenTelemetry.attach("req-llm-otel", adapter: MyApp.ReqLLMAdapter)

  See the Telemetry guide's caller-context section for when to use this
  versus a parent span or OTel baggage.
  """

  @callback available?() :: boolean()
  @callback start_span(String.t(), map(), keyword()) :: term()
  @callback set_attributes(term(), map(), keyword()) :: :ok
  @callback add_event(term(), atom() | String.t(), map(), keyword()) :: :ok
  @callback set_status(term(), :ok | :error, String.t() | nil, keyword()) :: :ok
  @callback end_span(term(), keyword()) :: :ok
  @callback metrics_available?() :: boolean()
  @callback record_histogram(map(), keyword()) :: :ok
  @callback start_child_span(
              parent :: term(),
              name :: String.t(),
              attributes :: map(),
              opts :: %{
                optional(:kind) => atom(),
                optional(:start_time) => integer()
              },
              config :: keyword()
            ) :: term()
  @callback end_span_at(span :: term(), end_time :: integer(), config :: keyword()) :: :ok

  @optional_callbacks metrics_available?: 0,
                      record_histogram: 2,
                      start_child_span: 5,
                      end_span_at: 3
end

defmodule ReqLLM.OpenTelemetry.OTelAdapter do
  @moduledoc """
  Default `ReqLLM.OpenTelemetry.Adapter` implementation, backed by the
  Erlang OpenTelemetry SDK (`:otel_tracer`, `:otel_span`, `:otel_meter`).

  Used automatically by `ReqLLM.OpenTelemetry.attach/2`. Public so that
  custom adapters can `defdelegate` the callbacks they don't need to
  override — see `ReqLLM.OpenTelemetry.Adapter` for the wrapping pattern.
  """

  @behaviour ReqLLM.OpenTelemetry.Adapter

  @instrument_table :req_llm_open_telemetry_instruments
  @otel_schema_url "https://opentelemetry.io/schemas/1.37.0"

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
  def metrics_available? do
    Enum.all?(
      [
        {:otel_meter_provider, :get_meter, 3},
        {:otel_meter, :create_histogram, 3},
        {:otel_histogram, :record, 4},
        {:otel_ctx, :get_current, 0}
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

  @impl true
  def start_child_span(parent, name, attributes, opts, config) do
    if child_span_available?() do
      ctx = call(:otel_ctx, :get_current, [])
      child_ctx = call(:otel_tracer, :set_current_span, [ctx, parent])

      span_opts =
        %{
          kind: Map.get(opts, :kind, :internal),
          attributes: attributes
        }
        |> maybe_put(:start_time, Map.get(opts, :start_time))

      call(:otel_tracer, :start_span, [child_ctx, tracer(), name, span_opts])
    else
      start_span(name, attributes, config)
    end
  end

  @impl true
  def end_span_at(span, end_time, config) when is_integer(end_time) do
    if Code.ensure_loaded?(:otel_span) and function_exported?(:otel_span, :end_span, 2) do
      call(:otel_span, :end_span, [span, end_time])
    else
      end_span(span, config)
    end

    :ok
  end

  defp child_span_available? do
    Enum.all?(
      [
        {:otel_ctx, :get_current, 0},
        {:otel_tracer, :set_current_span, 2},
        {:otel_tracer, :start_span, 4}
      ],
      fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @impl true
  def record_histogram(record, _config) do
    instrument = ensure_instrument(record)
    ctx = call(:otel_ctx, :get_current, [])

    call(:otel_histogram, :record, [
      ctx,
      instrument,
      record.value,
      atomize_keys(record.attributes)
    ])

    :ok
  end

  defp ensure_instrument(%{name: name} = record) do
    ensure_instrument_table()
    instrument_name = otel_instrument_name(name)

    case :ets.lookup(@instrument_table, instrument_name) do
      [{^instrument_name, instrument}] ->
        instrument

      [] ->
        instrument =
          call(:otel_meter, :create_histogram, [
            meter(),
            instrument_name,
            instrument_config(record)
          ])

        if :ets.insert_new(@instrument_table, {instrument_name, instrument}) do
          instrument
        else
          [{^instrument_name, existing}] = :ets.lookup(@instrument_table, instrument_name)
          existing
        end
    end
  end

  defp ensure_instrument_table do
    case :ets.whereis(@instrument_table) do
      :undefined ->
        :ets.new(@instrument_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ ->
        @instrument_table
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp instrument_config(record) do
    base = %{
      description: Map.get(record, :description, ""),
      unit: Map.get(record, :unit, "")
    }

    case Map.get(record, :boundaries, []) do
      [] ->
        base

      [_ | _] = boundaries ->
        Map.put(base, :advisory_params, %{explicit_bucket_boundaries: boundaries})
    end
  end

  defp otel_instrument_name(name) when is_atom(name), do: name
  defp otel_instrument_name(name), do: String.to_atom(name)

  # Keys come from the closed `gen_ai.*` / `server.*` / `error.*` set defined in
  # `ReqLLM.OpenTelemetry.{Attributes,Content,Metrics}` — not from caller-supplied
  # input — so `String.to_atom/1` is safe here. Do not pass user-supplied keys through.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
    end)
  end

  defp meter do
    call(
      :otel_meter_provider,
      :get_meter,
      [
        :req_llm,
        application_version(),
        @otel_schema_url
      ]
    )
  end

  defp tracer do
    call(
      :otel_tracer_provider,
      :get_tracer,
      [
        :req_llm,
        application_version(),
        @otel_schema_url
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
  alias ReqLLM.OpenTelemetry.{Attributes, SemConv, Translator}
  alias ReqLLM.Telemetry.OpenTelemetry, as: Mapper

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception]
  ]
  @default_handler_id "req-llm-open-telemetry"
  @span_table :req_llm_open_telemetry_spans
  @default_adapter ReqLLM.OpenTelemetry.OTelAdapter

  @type content_mode :: :none | :attributes | :event

  @type attach_opt ::
          {:adapter, module()}
          | {:handler_id, term()}
          | {:content, content_mode() | boolean()}
          | {:langfuse, boolean()}
          | {atom(), term()}

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

  Options:

  - `:adapter` — alternate adapter module (defaults to
    `ReqLLM.OpenTelemetry.OTelAdapter`).
  - `:content` — content capture mode. `:none` (default) emits no message
    payloads; `:attributes` promotes `gen_ai.input.messages`,
    `gen_ai.system_instructions`, `gen_ai.tool.definitions`, and
    `gen_ai.output.messages` onto the span; `:event` emits the same payload
    as a single `gen_ai.client.inference.operation.details` span event on
    the terminal lifecycle event. `true` is accepted as an alias for
    `:attributes`.
  - `:langfuse` — when `true`, also adds `langfuse.observation.cost_details`
    (JSON-encoded breakdown) when ReqLLM has computed a cost.

  Content capture additionally requires `telemetry: [payloads: :raw]` on the
  call so the request/response payloads are available to map.

  In-flight spans are tracked in a named ETS table keyed by handler id and
  request id. If a `:start` event is observed but no `:stop`/`:exception`
  follows (e.g. the calling process crashed before emission), the entry stays
  in the table until `detach/1` runs. Long-running hosts can call
  `prune_stale_spans/2` periodically to clear out entries older than a TTL.
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
    :ets.match_delete(@span_table, {{handler_id, :_}, :_, :_})
    :telemetry.detach(handler_id)
  end

  @doc """
  Removes in-flight span entries older than `ttl_ms` for `handler_id`.

  Returns the number of entries pruned. Use this from a host-side scheduler
  (e.g. an `:erlang.send_after/3` loop or a periodic GenServer tick) to
  contain the ETS table when requests start without a matching stop or
  exception event.
  """
  @spec prune_stale_spans(term(), non_neg_integer()) :: non_neg_integer()
  def prune_stale_spans(handler_id \\ @default_handler_id, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms >= 0 do
    ensure_span_table()
    cutoff_ms = System.monotonic_time(:millisecond) - ttl_ms

    @span_table
    |> :ets.match_object({{handler_id, :_}, :_, :_})
    |> Enum.reduce(0, fn {key, _span, inserted_at_ms}, acc ->
      if inserted_at_ms <= cutoff_ms do
        :ets.delete(@span_table, key)
        acc + 1
      else
        acc
      end
    end)
  end

  @doc """
  Returns the GenAI span name for a ReqLLM request.
  """
  @spec span_name(map()) :: String.t()
  def span_name(metadata) do
    SemConv.span_name(
      MapAccess.get(metadata, :operation),
      Attributes.request_model(metadata) || "unknown"
    )
  end

  @doc false
  @spec handle_event(list(atom()), map(), map(), keyword()) :: :ok
  def handle_event([:req_llm, :request, :start], _measurements, metadata, config) do
    ensure_span_table()

    if request_id = MapAccess.get(metadata, :request_id) do
      stub = Mapper.request_start(metadata, config)
      span = Translator.apply_start(stub, adapter(config), config)

      :ets.insert(
        @span_table,
        {span_key(config, request_id), span, System.monotonic_time(:millisecond)}
      )
    end

    :ok
  end

  def handle_event([:req_llm, :request, :stop], measurements, metadata, config) do
    with request_id when is_binary(request_id) <- MapAccess.get(metadata, :request_id),
         {:ok, span} <- take_span(config, request_id) do
      stub = Mapper.request_stop(metadata, terminal_opts(config, measurements))
      Translator.apply_terminal(span, stub, adapter(config), config)
    end

    :ok
  end

  def handle_event([:req_llm, :request, :exception], measurements, metadata, config) do
    with request_id when is_binary(request_id) <- MapAccess.get(metadata, :request_id),
         {:ok, span} <- take_span(config, request_id) do
      stub = Mapper.request_exception(metadata, terminal_opts(config, measurements))
      Translator.apply_terminal(span, stub, adapter(config), config)
    end

    :ok
  end

  defp config(handler_id, opts) do
    adapter = Keyword.get(opts, :adapter, @default_adapter)

    opts
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put(:handler_id, handler_id)
    |> Keyword.put(:metrics_enabled?, metrics_enabled?(adapter))
  end

  defp adapter(opts), do: Keyword.get(opts, :adapter, @default_adapter)

  defp metrics_enabled?(adapter) do
    function_exported?(adapter, :metrics_available?, 0) and
      function_exported?(adapter, :record_histogram, 2) and
      adapter.metrics_available?()
  end

  defp terminal_opts(config, measurements) do
    Keyword.put(config, :measurements, measurements || %{})
  end

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
      [{^key, span, _inserted_at}] ->
        :ets.delete(@span_table, key)
        {:ok, span}

      [] ->
        :error
    end
  end
end
