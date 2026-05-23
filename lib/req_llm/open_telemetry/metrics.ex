defmodule ReqLLM.OpenTelemetry.Metrics do
  @moduledoc """
  Builds histogram records for the four OpenTelemetry GenAI client metrics:
  `gen_ai.client.operation.duration`, `gen_ai.client.token.usage`,
  `gen_ai.client.operation.time_to_first_chunk`, and
  `gen_ai.client.operation.time_per_output_chunk`.

  Shared between `ReqLLM.OpenTelemetry` (which feeds them to an OTel meter)
  and `ReqLLM.Telemetry.OpenTelemetry` (which returns them in the span stub).

  `stop/2` returns a list of records like:

      %{
        name: "gen_ai.client.operation.duration",
        value: 0.412,
        unit: "s",
        description: "GenAI operation duration.",
        boundaries: [0.01, 0.02, 0.04, ...],
        attributes: %{
          "gen_ai.operation.name" => "chat",
          "gen_ai.provider.name" => "openai",
          "gen_ai.request.model" => "gpt-5",
          "gen_ai.response.model" => "gpt-5-2025-04-01",
          "server.address" => "api.openai.com",
          "server.port" => 443
        }
      }

  TTFC and TPOC records are only emitted for `mode: :stream` requests that
  observed at least one non-empty content chunk. Token histograms emit on
  `:stop` only; `exception/2` emits the duration record with `error.type`
  populated so failures stay visible in latency charts.

  ## Bucket boundaries

  The bucket boundaries on each record (`@duration_boundaries`,
  `@token_boundaries`) are mandated by the OpenTelemetry GenAI metrics
  spec, not chosen by ReqLLM. Backends like Prometheus need fixed
  boundaries baked into the instrument at creation time, and the spec
  defines them up-front so different GenAI clients produce histograms a
  dashboard can compare apples-to-apples.

  The two scales reflect what LLM workloads actually look like:

    * **Durations** double from 10 ms up to ~82 s
      (`[0.01, 0.02, 0.04, …, 81.92]`) — short embeddings calls and long
      reasoning streams both fit in the same histogram with useful
      resolution.
    * **Token counts** quadruple from 1 up to ~67 M
      (`[1, 4, 16, …, 67_108_864]`) — single-token completions and
      multi-million-token context windows both stay on-scale.

  Exposed via `duration_boundaries/0` and `token_boundaries/0` for hosts
  that wire up custom histogram instruments themselves.
  """

  alias ReqLLM.MapAccess
  alias ReqLLM.OpenTelemetry.{Attributes, SemConv}

  @duration_boundaries [
    0.01,
    0.02,
    0.04,
    0.08,
    0.16,
    0.32,
    0.64,
    1.28,
    2.56,
    5.12,
    10.24,
    20.48,
    40.96,
    81.92
  ]

  @token_boundaries [
    1,
    4,
    16,
    64,
    256,
    1024,
    4096,
    16_384,
    65_536,
    262_144,
    1_048_576,
    4_194_304,
    16_777_216,
    67_108_864
  ]

  @duration_metric "gen_ai.client.operation.duration"
  @token_metric "gen_ai.client.token.usage"
  @ttfc_metric "gen_ai.client.operation.time_to_first_chunk"
  @tpoc_metric "gen_ai.client.operation.time_per_output_chunk"

  @type histogram_record :: %{
          name: String.t(),
          value: number(),
          unit: String.t(),
          description: String.t(),
          boundaries: [number()],
          attributes: map()
        }

  @doc "Spec bucket boundaries for duration histograms (seconds)."
  @spec duration_boundaries() :: [number()]
  def duration_boundaries, do: @duration_boundaries

  @doc "Spec bucket boundaries for token histograms (tokens)."
  @spec token_boundaries() :: [number()]
  def token_boundaries, do: @token_boundaries

  @doc """
  Builds histogram records to emit on `[:req_llm, :request, :stop]`.

  `duration` is in `:native` time units. Returns `[]` when `duration` is
  unavailable — without a duration the per-request metric set isn't
  meaningful.
  """
  @spec stop(map(), integer() | nil) :: [histogram_record()]
  def stop(_metadata, nil), do: []

  def stop(metadata, duration) when is_integer(duration) do
    base = base_attributes(metadata)

    [duration_record(to_seconds(duration), duration_attributes(metadata, base))]
    |> Kernel.++(token_records(metadata, base))
    |> Kernel.++(streaming_records(metadata, base, duration))
  end

  @doc """
  Builds histogram records to emit on `[:req_llm, :request, :exception]`.

  Records the duration histogram with `error.type` populated. Token and
  streaming histograms are intentionally skipped — usage and chunk timings
  are not reliable on exception. Returns `[]` when `duration` is unavailable.
  """
  @spec exception(map(), integer() | nil) :: [histogram_record()]
  def exception(_metadata, nil), do: []

  def exception(metadata, duration) when is_integer(duration) do
    base = base_attributes(metadata)

    [duration_record(to_seconds(duration), error_attributes(metadata, base))]
  end

  defp duration_record(duration_seconds, attributes) do
    %{
      name: @duration_metric,
      value: duration_seconds,
      unit: "s",
      description: "GenAI operation duration.",
      boundaries: @duration_boundaries,
      attributes: attributes
    }
  end

  defp token_records(metadata, base) do
    case MapAccess.get(metadata, :usage) do
      usage when is_map(usage) ->
        tokens = token_pairs(usage)

        Enum.map(tokens, fn {type, value} ->
          %{
            name: @token_metric,
            value: value,
            unit: "{token}",
            description: "Measures number of input and output tokens used.",
            boundaries: @token_boundaries,
            attributes: Map.put(base, "gen_ai.token.type", type)
          }
        end)

      _ ->
        []
    end
  end

  defp streaming_records(metadata, base, duration) do
    case streaming_inputs(metadata, duration) do
      nil ->
        []

      %{ttfc_seconds: ttfc, tpoc_seconds: tpoc} ->
        [
          ttfc &&
            %{
              name: @ttfc_metric,
              value: ttfc,
              unit: "s",
              description: "Time to first content chunk in a streaming GenAI operation.",
              boundaries: @duration_boundaries,
              attributes: base
            },
          tpoc &&
            %{
              name: @tpoc_metric,
              value: tpoc,
              unit: "s",
              description: "Time per output chunk in a streaming GenAI operation.",
              boundaries: @duration_boundaries,
              attributes: base
            }
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp streaming_inputs(metadata, duration) do
    case MapAccess.get(metadata, :mode) do
      :stream ->
        streaming = MapAccess.get(metadata, :streaming) || %{}
        ttfc_native = MapAccess.get(streaming, :time_to_first_chunk)
        ttfc = to_seconds(ttfc_native)
        tpoc = compute_tpoc(duration, ttfc_native, MapAccess.get(metadata, :usage))

        if is_nil(ttfc) and is_nil(tpoc) do
          nil
        else
          %{ttfc_seconds: ttfc, tpoc_seconds: tpoc}
        end

      _ ->
        nil
    end
  end

  defp compute_tpoc(duration, ttfc_native, usage)
       when is_integer(duration) and is_integer(ttfc_native) and duration > ttfc_native do
    case output_token_count(usage) do
      tokens when is_integer(tokens) and tokens > 0 ->
        to_seconds(duration - ttfc_native) / tokens

      _ ->
        nil
    end
  end

  defp compute_tpoc(_duration, _ttfc, _usage), do: nil

  defp output_token_count(usage) when is_map(usage) do
    tokens =
      case MapAccess.get(usage, :tokens) do
        tokens when is_map(tokens) -> tokens
        _ -> usage
      end

    MapAccess.get(tokens, :output) || MapAccess.get(tokens, :output_tokens)
  end

  defp output_token_count(_), do: nil

  defp token_pairs(usage) do
    tokens =
      case MapAccess.get(usage, :tokens) do
        tokens when is_map(tokens) -> tokens
        _ -> usage
      end

    [
      {"input", MapAccess.get(tokens, :input) || MapAccess.get(tokens, :input_tokens)},
      {"output", MapAccess.get(tokens, :output) || MapAccess.get(tokens, :output_tokens)}
    ]
    |> Enum.reject(fn {_type, value} -> is_nil(value) end)
  end

  defp base_attributes(metadata) do
    request_model = Attributes.request_model(metadata)
    response_model = response_model(metadata) || request_model
    server = MapAccess.get(metadata, :server) || %{}

    %{
      "gen_ai.operation.name" => SemConv.operation_name(MapAccess.get(metadata, :operation)),
      "gen_ai.provider.name" => Attributes.provider_name(metadata),
      "gen_ai.request.model" => request_model,
      "gen_ai.response.model" => response_model,
      "server.address" => MapAccess.get(server, :address),
      "server.port" => MapAccess.get(server, :port)
    }
    |> drop_nils()
  end

  defp duration_attributes(metadata, base) do
    case http_error_type(metadata) do
      nil -> base
      type -> Map.put(base, "error.type", type)
    end
  end

  defp error_attributes(metadata, base),
    do: Map.put(base, "error.type", Attributes.error_type(metadata))

  defp http_error_type(metadata) do
    case MapAccess.get(metadata, :http_status) do
      status when is_integer(status) and status >= 400 -> Integer.to_string(status)
      _ -> nil
    end
  end

  defp response_model(metadata) do
    case MapAccess.get(metadata, :response_payload) do
      %ReqLLM.Response{model: model} when is_binary(model) and model != "" -> model
      payload when is_map(payload) -> Attributes.present(MapAccess.get(payload, :model))
      _ -> nil
    end
  end

  defp to_seconds(nil), do: nil
  defp to_seconds(0), do: 0.0

  defp to_seconds(native) when is_integer(native) do
    System.convert_time_unit(native, :native, :microsecond) / 1_000_000
  end

  defp to_seconds(seconds) when is_float(seconds), do: seconds
  defp to_seconds(_), do: nil

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
