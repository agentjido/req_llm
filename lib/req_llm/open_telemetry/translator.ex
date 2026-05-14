defmodule ReqLLM.OpenTelemetry.Translator do
  @moduledoc false

  # Stateless translator: turns request-lifecycle stubs produced by
  # `ReqLLM.Telemetry.OpenTelemetry` into adapter calls. Lets the live
  # bridge stay a thin shell while the mapper remains the single source
  # of truth for span shape (attributes, events, status, metrics).
  #
  # Atomization of attribute and event-name keys happens here so the
  # mapper can keep returning binary keys (which dep-free callers can
  # hand straight to any tracer SDK).

  @doc """
  Starts a span from a `Mapper.request_start/2` stub. Emits any pre-start
  events (none today, but the contract is preserved).
  """
  @spec apply_start(map(), module(), keyword()) :: term()
  def apply_start(stub, adapter, config) do
    span = adapter.start_span(stub.name, atomize(stub.attributes), config)
    Enum.each(stub.events, &emit_event(adapter, span, &1, config))
    span
  end

  @doc """
  Applies a terminal stub (`Mapper.request_stop/2` or
  `Mapper.request_exception/2`) to an existing span: sets attributes,
  emits events in order, emits `gen_ai.execute_tool` sub-spans for
  server-side builtin tool calls, applies status, ends the span, and
  records metrics.
  """
  @spec apply_terminal(term(), map(), module(), keyword()) :: :ok
  def apply_terminal(span, stub, adapter, config) do
    adapter.set_attributes(span, atomize(stub.attributes), config)
    Enum.each(stub.events, &emit_event(adapter, span, &1, config))
    Enum.each(Map.get(stub, :tool_spans, []), &emit_tool_span(span, &1, adapter, config))
    apply_status(span, stub.status, adapter, config)
    adapter.end_span(span, config)
    record_metrics(stub.metrics, adapter, config)
  end

  defp emit_event(adapter, span, %{name: name, attributes: attrs}, config) do
    adapter.add_event(span, atomize_name(name), atomize(attrs), config)
  end

  # Emits a `gen_ai.execute_tool` sub-span as a child of `parent`. The
  # adapter is expected to expose the optional `start_child_span/5` and
  # `end_span_at/3` callbacks for nested + explicitly-timed spans; if
  # they're absent we fall back to `start_span/3` + `end_span/2`, which
  # records the same data but loses the parent-child relationship and
  # the measured-duration timestamps.
  defp emit_tool_span(parent, stub, adapter, config) do
    name = stub.name
    attrs = atomize(stub.attributes)
    start_opts = build_start_opts(stub)

    child =
      if function_exported?(adapter, :start_child_span, 5) do
        adapter.start_child_span(parent, name, attrs, start_opts, config)
      else
        adapter.start_span(name, attrs, config)
      end

    apply_status(child, stub.status, adapter, config)

    if is_integer(stub.end_time) and function_exported?(adapter, :end_span_at, 3) do
      adapter.end_span_at(child, stub.end_time, config)
    else
      adapter.end_span(child, config)
    end
  end

  defp build_start_opts(stub) do
    base = %{kind: Map.get(stub, :kind, :internal)}

    case stub.start_time do
      t when is_integer(t) -> Map.put(base, :start_time, t)
      _ -> base
    end
  end

  defp apply_status(_span, :ok, _adapter, _config), do: :ok

  defp apply_status(span, {:error, message}, adapter, config) do
    adapter.set_status(span, :error, message, config)
  end

  defp record_metrics(records, adapter, config) when is_list(records) do
    # `record_histogram/2` is an `@optional_callbacks` member of the
    # adapter behaviour. Even when `metrics_enabled?` is set, double-check
    # the adapter actually exports it so misconfigured callers fail
    # gracefully (skip metrics) instead of with an `UndefinedFunctionError`.
    if Keyword.get(config, :metrics_enabled?, false) and
         function_exported?(adapter, :record_histogram, 2) do
      Enum.each(records, &adapter.record_histogram(&1, config))
    end

    :ok
  end

  defp record_metrics(_records, _adapter, _config), do: :ok

  # Keys/names come from the closed `gen_ai.*` / `server.*` / `error.*` /
  # `req_llm.*` / `openai.*` / `langfuse.*` set defined in `Attributes`,
  # `Content`, `Metrics`, and `Shared` — not caller-supplied — so
  # `String.to_atom/1` is safe. Do not feed user input here.
  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
    end)
  end

  defp atomize_name(name) when is_atom(name), do: name
  defp atomize_name(name) when is_binary(name), do: String.to_atom(name)
end
