defmodule ReqLLM.Telemetry.OpenTelemetry do
  @moduledoc """
  Dependency-free helpers for mapping ReqLLM telemetry metadata to
  OpenTelemetry GenAI span data.

  This module does not depend on an OpenTelemetry SDK and does not start or stop
  spans on your behalf. Instead, it translates ReqLLM's native `:telemetry`
  metadata into:

  - GenAI span names
  - GenAI span attributes
  - span status hints
  - span events (`exception`, optional `gen_ai.client.inference.operation.details`)

  Content capture is opt-in through the `:content` option:

  - `:none` (default) — no message, instructions, or tool definitions are emitted.
  - `:attributes` — `gen_ai.input.messages`, `gen_ai.system_instructions`,
    `gen_ai.tool.definitions`, and `gen_ai.output.messages` are attached as
    span attributes.
  - `:event` — the same payload is attached to a single
    `gen_ai.client.inference.operation.details` span event instead of the
    span attributes.

  When content capture is on, ReqLLM request telemetry must also enable payload
  capture with `telemetry: [payloads: :raw]`, otherwise the request payload is
  not available to map.

  Reasoning text remains redacted in every content mode — reasoning parts are
  intentionally omitted from `gen_ai.input.messages` / `gen_ai.output.messages`.
  """

  alias ReqLLM.MapAccess
  alias ReqLLM.OpenTelemetry.{Attributes, Content, Metrics, SemConv, Shared}
  alias ReqLLM.{Response, ToolCall}

  @type content_mode :: :none | :attributes | :event
  @type span_status :: :ok | {:error, String.t()}
  @type otel_event :: %{name: String.t(), attributes: map()}
  @type metric_record :: Metrics.histogram_record()

  @type tool_span_stub :: %{
          name: String.t(),
          kind: :internal,
          attributes: map(),
          status: span_status(),
          start_time: integer() | nil,
          end_time: integer() | nil
        }

  @type request_start_stub :: %{
          name: String.t(),
          kind: :client,
          attributes: map(),
          events: [otel_event()]
        }

  @type request_terminal_stub :: %{
          attributes: map(),
          status: span_status(),
          events: [otel_event()],
          metrics: [metric_record()],
          tool_spans: [tool_span_stub()]
        }

  @inference_event_name "gen_ai.client.inference.operation.details"

  @doc """
  Builds span creation data for a `[:req_llm, :request, :start]` event.

  In `content: :event` mode the inference event payload is intentionally
  deferred to the terminal stub (`request_stop/2` / `request_exception/2`)
  so the host emits exactly one `gen_ai.client.inference.operation.details`
  event per span, carrying both request and response content. Start-side
  request content is still attached as span attributes when
  `content: :attributes`.
  """
  @spec request_start(map(), keyword()) :: request_start_stub()
  def request_start(metadata, opts \\ []) when is_map(metadata) do
    mode = Shared.content_mode(opts)
    request_content = content_for(mode, metadata, :request)

    %{
      name: span_name(metadata),
      kind: :client,
      attributes:
        metadata
        |> Attributes.start()
        |> merge_when(mode == :attributes, request_content),
      events: []
    }
  end

  @doc """
  Builds terminal span data for a `[:req_llm, :request, :stop]` event.

  Pass `measurements: %{duration: native}` to populate `metrics` and the
  `gen_ai.response.time_to_first_chunk` span attribute on streaming requests.
  Pass `langfuse: true` to add `langfuse.observation.cost_details` (JSON-encoded)
  whenever ReqLLM has computed a cost breakdown.
  """
  @spec request_stop(map(), keyword()) :: request_terminal_stub()
  def request_stop(metadata, opts \\ []) when is_map(metadata) do
    mode = Shared.content_mode(opts)
    measurements = measurements(opts)
    content_payload = content_for(mode, metadata, :both)
    base_attributes = metadata |> Attributes.start() |> Map.merge(Attributes.terminal(metadata))

    %{
      attributes:
        base_attributes
        |> merge_when(mode == :attributes, content_payload)
        |> Shared.merge_langfuse(metadata, opts),
      status: span_status(metadata),
      events:
        maybe_inference_event(mode, content_payload, Map.merge(base_attributes, content_payload)),
      metrics: Metrics.stop(metadata, MapAccess.get(measurements, :duration)),
      tool_spans: tool_spans(metadata, opts)
    }
  end

  @doc """
  Builds terminal span data for a `[:req_llm, :request, :exception]` event.
  """
  @spec request_exception(map(), keyword()) :: request_terminal_stub()
  def request_exception(metadata, opts \\ []) when is_map(metadata) do
    mode = Shared.content_mode(opts)
    measurements = measurements(opts)
    request_content = content_for(mode, metadata, :request)
    base_attributes = metadata |> Attributes.start() |> Map.merge(Attributes.exception(metadata))

    %{
      attributes:
        base_attributes
        |> merge_when(mode == :attributes, request_content),
      status: span_status(metadata),
      events:
        exception_events(metadata) ++
          maybe_inference_event(
            mode,
            request_content,
            Map.merge(base_attributes, request_content)
          ),
      metrics: Metrics.exception(metadata, MapAccess.get(measurements, :duration)),
      tool_spans: []
    }
  end

  @doc """
  Builds `gen_ai.execute_tool` sub-span stubs for server-side builtin
  tool calls present on the response message.

  Only entries flagged via `ReqLLM.ToolCall.builtin?/1` are surfaced —
  user-defined function tool execution happens in the caller's process
  and must be instrumented there.

  When `metadata.builtin_tool_timing` carries wall-clock nanoseconds for
  a given call id (streaming path), the stub propagates `start_time` /
  `end_time` so the translator can emit a span with the measured
  duration. Otherwise the fields are `nil`, and the translator falls
  back to "start span / end span" back-to-back — effectively a
  zero-width marker recording that the invocation occurred inside the
  parent's lifetime.
  """
  @spec tool_spans(map(), keyword()) :: [tool_span_stub()]
  def tool_spans(metadata, _opts \\ []) when is_map(metadata) do
    metadata
    |> response_tool_calls()
    |> Enum.filter(&ToolCall.builtin?/1)
    |> Enum.map(&build_tool_span_stub(&1, metadata))
    |> Enum.reject(&is_nil/1)
  end

  defp response_tool_calls(metadata) do
    case MapAccess.get(metadata, :response_payload) do
      %Response{message: %{tool_calls: calls}} when is_list(calls) -> calls
      %{message: %{tool_calls: calls}} when is_list(calls) -> calls
      %{"message" => %{"tool_calls" => calls}} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp build_tool_span_stub(%ToolCall{} = tc, metadata) do
    build_tool_span_stub(ToolCall.name(tc), ToolCall.args_map(tc), tc.id, metadata)
  end

  defp build_tool_span_stub(tool_call, metadata) when is_map(tool_call) do
    function = MapAccess.get(tool_call, :function, %{})
    name = MapAccess.get(function, :name) || MapAccess.get(tool_call, :name)
    args = args_from_map_tool_call(tool_call, function)
    id = MapAccess.get(tool_call, :id)

    build_tool_span_stub(name, args, id, metadata)
  end

  defp build_tool_span_stub(name, args, id, metadata) when is_binary(name) do
    timing = MapAccess.get(metadata, :builtin_tool_timing) || %{}
    entry = timing_entry(timing, id)
    {start_time, end_time} = span_timing(entry)

    %{
      name: "execute_tool " <> name,
      kind: :internal,
      status: :ok,
      start_time: start_time,
      end_time: end_time,
      attributes:
        %{
          "gen_ai.operation.name" => "execute_tool",
          "gen_ai.tool.name" => name,
          "gen_ai.tool.type" => "builtin",
          "gen_ai.tool.call.id" => id
        }
        |> maybe_put_arguments(args)
    }
  end

  defp build_tool_span_stub(_name, _args, _id, _metadata), do: nil

  defp timing_entry(timing, nil), do: timing_entry(timing, "")
  defp timing_entry(timing, id), do: Map.get(timing, id) || Map.get(timing, to_string(id)) || %{}

  defp span_timing(entry) do
    start_time = MapAccess.get(entry, :start_unix_nano)
    end_time = MapAccess.get(entry, :end_unix_nano)

    if is_integer(start_time) and is_integer(end_time) and end_time >= start_time do
      {start_time, end_time}
    else
      {nil, nil}
    end
  end

  defp args_from_map_tool_call(tool_call, function) do
    case MapAccess.get(function, :arguments) || MapAccess.get(tool_call, :arguments) do
      args when is_binary(args) -> decode_arguments(args)
      args when is_map(args) -> args
      _ -> %{}
    end
  end

  defp decode_arguments(args) do
    case ReqLLM.JSON.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp maybe_put_arguments(attrs, args) when is_map(args) and map_size(args) > 0 do
    case Jason.encode(args) do
      {:ok, json} -> Map.put(attrs, "gen_ai.tool.call.arguments", json)
      _ -> attrs
    end
  end

  defp maybe_put_arguments(attrs, _), do: attrs

  defp span_name(metadata) do
    SemConv.span_name(
      MapAccess.get(metadata, :operation),
      requested_model_id(MapAccess.get(metadata, :model))
    )
  end

  defp measurements(opts) do
    case Keyword.get(opts, :measurements) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp content_for(:none, _metadata, _scope), do: %{}

  defp content_for(:event, metadata, :request), do: Content.request_event_attributes(metadata)

  defp content_for(:event, metadata, :both) do
    Map.merge(
      Content.request_event_attributes(metadata),
      Content.response_event_attributes(metadata)
    )
  end

  defp content_for(_mode, metadata, :request), do: Content.request_attributes(metadata)

  defp content_for(_mode, metadata, :both) do
    Map.merge(Content.request_attributes(metadata), Content.response_attributes(metadata))
  end

  defp merge_when(map, true, addition), do: Map.merge(map, addition)
  defp merge_when(map, false, _addition), do: map

  defp maybe_inference_event(:event, content_payload, event_payload)
       when map_size(content_payload) > 0 do
    [%{name: @inference_event_name, attributes: event_payload}]
  end

  defp maybe_inference_event(_mode, _content_payload, _event_payload), do: []

  defp requested_model_id(%{id: id}) when is_binary(id), do: id
  defp requested_model_id(_), do: ""

  defp span_status(metadata) do
    error = MapAccess.get(metadata, :error)
    http_status = MapAccess.get(metadata, :http_status)
    finish_reason = MapAccess.get(metadata, :finish_reason)

    cond do
      not is_nil(error) ->
        {:error, Shared.error_message(error)}

      is_integer(http_status) and http_status >= 400 ->
        {:error, "HTTP #{http_status}"}

      finish_reason in [:error, "error"] ->
        {:error, "request failed"}

      true ->
        :ok
    end
  end

  defp exception_events(metadata) do
    case MapAccess.get(metadata, :error) do
      nil -> []
      _error -> [%{name: "exception", attributes: Attributes.exception_event(metadata)}]
    end
  end
end
