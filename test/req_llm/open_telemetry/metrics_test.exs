defmodule ReqLLM.OpenTelemetry.MetricsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry.Metrics

  defp model, do: %LLMDB.Model{id: "gpt-5", provider: :openai}

  defp base_metadata(extra \\ %{}) do
    Map.merge(
      %{
        request_id: "req-1",
        operation: :chat,
        mode: :sync,
        provider: :openai,
        model: model(),
        server: %{address: "api.openai.com", port: 443},
        usage: %{tokens: %{input: 100, output: 50}},
        response_payload: %{model: "gpt-5-2026-04"}
      },
      extra
    )
  end

  defp one_second, do: System.convert_time_unit(1, :second, :native)
  defp millisecond_to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp by_name(records, name), do: Enum.filter(records, &(&1.name == name))
  defp first(records, name), do: records |> by_name(name) |> List.first()

  test "stop/2 records duration with full GenAI metric attributes" do
    records = Metrics.stop(base_metadata(), one_second())
    duration = first(records, "gen_ai.client.operation.duration")

    assert duration.unit == "s"
    assert_in_delta(duration.value, 1.0, 0.001)
    assert duration.boundaries == Metrics.duration_boundaries()

    assert duration.attributes == %{
             "gen_ai.operation.name" => "chat",
             "gen_ai.provider.name" => "openai",
             "gen_ai.request.model" => "gpt-5",
             "gen_ai.response.model" => "gpt-5-2026-04",
             "server.address" => "api.openai.com",
             "server.port" => 443
           }
  end

  test "stop/2 records token.usage once per type with token boundaries" do
    records = Metrics.stop(base_metadata(), one_second())
    tokens = by_name(records, "gen_ai.client.token.usage")

    assert length(tokens) == 2
    assert Enum.all?(tokens, &(&1.unit == "{token}"))
    assert Enum.all?(tokens, &(&1.boundaries == Metrics.token_boundaries()))

    by_type = Map.new(tokens, &{&1.attributes["gen_ai.token.type"], &1.value})
    assert by_type == %{"input" => 100, "output" => 50}
  end

  test "stop/2 emits no streaming records for sync requests" do
    records = Metrics.stop(base_metadata(), one_second())
    assert by_name(records, "gen_ai.client.operation.time_to_first_chunk") == []
    assert by_name(records, "gen_ai.client.operation.time_per_output_chunk") == []
  end

  test "stop/2 emits TTFC and TPOC for streaming requests with output tokens" do
    metadata =
      base_metadata(%{
        mode: :stream,
        streaming: %{
          first_chunk_at: 0,
          time_to_first_chunk: millisecond_to_native(200)
        },
        usage: %{tokens: %{input: 100, output: 50}}
      })

    records = Metrics.stop(metadata, millisecond_to_native(1200))

    ttfc = first(records, "gen_ai.client.operation.time_to_first_chunk")
    tpoc = first(records, "gen_ai.client.operation.time_per_output_chunk")

    assert_in_delta(ttfc.value, 0.2, 0.001)
    assert ttfc.unit == "s"
    assert ttfc.boundaries == Metrics.duration_boundaries()
    refute Map.has_key?(ttfc.attributes, "gen_ai.token.type")

    assert_in_delta(tpoc.value, (1.2 - 0.2) / 50, 0.001)
    assert tpoc.unit == "s"
    refute Map.has_key?(tpoc.attributes, "gen_ai.token.type")
  end

  test "stop/2 omits TPOC when output_tokens is zero or missing" do
    metadata =
      base_metadata(%{
        mode: :stream,
        streaming: %{
          first_chunk_at: 0,
          time_to_first_chunk: millisecond_to_native(200)
        },
        usage: %{tokens: %{input: 10, output: 0}}
      })

    records = Metrics.stop(metadata, millisecond_to_native(1200))
    assert by_name(records, "gen_ai.client.operation.time_per_output_chunk") == []
    assert [_ttfc] = by_name(records, "gen_ai.client.operation.time_to_first_chunk")
  end

  test "stop/2 omits TPOC when duration is not greater than TTFC" do
    metadata =
      base_metadata(%{
        mode: :stream,
        streaming: %{first_chunk_at: 0, time_to_first_chunk: millisecond_to_native(1200)},
        usage: %{tokens: %{input: 10, output: 50}}
      })

    records = Metrics.stop(metadata, millisecond_to_native(1200))
    assert by_name(records, "gen_ai.client.operation.time_per_output_chunk") == []
  end

  test "stop/2 sets error.type on duration when http_status >= 400" do
    metadata = base_metadata(%{http_status: 503, usage: nil})
    records = Metrics.stop(metadata, one_second())
    duration = first(records, "gen_ai.client.operation.duration")

    assert duration.attributes["error.type"] == "503"
    assert by_name(records, "gen_ai.client.token.usage") == []
  end

  test "exception/2 records duration with error.type and skips token + streaming" do
    metadata =
      base_metadata(%{
        mode: :stream,
        usage: nil,
        error: %RuntimeError{message: "boom"}
      })

    records = Metrics.exception(metadata, one_second())
    duration = first(records, "gen_ai.client.operation.duration")

    assert length(records) == 1
    assert duration.attributes["error.type"] == "RuntimeError"
    assert by_name(records, "gen_ai.client.token.usage") == []
    assert by_name(records, "gen_ai.client.operation.time_to_first_chunk") == []
  end

  test "stop/2 falls back to gen_ai.request.model when response_payload is missing" do
    records = Metrics.stop(base_metadata(%{response_payload: nil}), one_second())
    duration = first(records, "gen_ai.client.operation.duration")
    assert duration.attributes["gen_ai.response.model"] == "gpt-5"
  end

  test "stop/2 returns no records for nil duration" do
    metadata = base_metadata(%{usage: nil})
    assert Metrics.stop(metadata, nil) == []
  end

  test "stop/2 still records token.usage when value is zero" do
    metadata = base_metadata(%{usage: %{tokens: %{input: 100, output: 0}}})
    records = Metrics.stop(metadata, one_second())
    tokens = by_name(records, "gen_ai.client.token.usage")

    by_type = Map.new(tokens, &{&1.attributes["gen_ai.token.type"], &1.value})
    assert by_type == %{"input" => 100, "output" => 0}
  end

  test "exception/2 returns no records for nil duration" do
    assert Metrics.exception(base_metadata(), nil) == []
  end
end
