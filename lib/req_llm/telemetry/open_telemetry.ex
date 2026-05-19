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

  @type content_mode :: :none | :attributes | :event
  @type span_status :: :ok | {:error, String.t()}
  @type otel_event :: %{name: String.t(), attributes: map()}
  @type metric_record :: map()

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
          metrics: [metric_record()]
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
      metrics: Metrics.stop(metadata, MapAccess.get(measurements, :duration))
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
      metrics: Metrics.exception(metadata, MapAccess.get(measurements, :duration))
    }
  end

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
