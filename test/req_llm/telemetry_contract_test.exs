defmodule ReqLLM.TelemetryContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ReqLLM.Context

  alias ReqLLM.Provider.ChunkAccumulator

  @stable_events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception],
    [:req_llm, :token_usage]
  ]

  @experimental_events [
    [:req_llm, :request, :retry],
    [:req_llm, :reasoning, :start],
    [:req_llm, :reasoning, :update],
    [:req_llm, :reasoning, :stop],
    [:req_llm, :tool_call_args_lost]
  ]

  setup do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        ReqLLM.Telemetry.events(),
        fn name, measurements, metadata, pid ->
          send(pid, {:telemetry_contract_event, name, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "publishes the complete and stable V1 event inventories" do
    assert ReqLLM.Telemetry.stable_events() == @stable_events
    assert ReqLLM.Telemetry.experimental_events() == @experimental_events
    assert ReqLLM.Telemetry.events() == @stable_events ++ @experimental_events
    assert Enum.uniq(ReqLLM.Telemetry.events()) == ReqLLM.Telemetry.events()
  end

  test "preserves stable lifecycle, usage, streaming, and retry shapes" do
    model = %LLMDB.Model{provider: :openai, id: "gpt-5"}
    usage = %{tokens: %{input: 3, output: 2, total_tokens: 5, reasoning: 0}, cost: nil}

    context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), total_timeout: 30_000],
        operation: :chat,
        mode: :stream,
        transport: :finch
      )
      |> ReqLLM.Telemetry.start_request(%{})

    :ok =
      ReqLLM.Telemetry.retry_request(context, %{
        duration: 17,
        attempt: 1,
        next_attempt: 2,
        max_retries: 3,
        delay: 25,
        http_status: 429
      })

    context = ReqLLM.Telemetry.observe_stream_chunk(context, ReqLLM.StreamChunk.text("hello"))

    ReqLLM.Telemetry.stop_request(context, %{finish_reason: :stop, usage: usage},
      usage: usage,
      finish_reason: :stop,
      http_status: 200,
      emit_token_usage?: true
    )

    events = collect_events()
    start = single_event(events, [:req_llm, :request, :start])
    retry = single_event(events, [:req_llm, :request, :retry])
    stop = single_event(events, [:req_llm, :request, :stop])
    token_usage = single_event(events, [:req_llm, :token_usage])

    assert_keys(start.measurements, [:system_time])
    assert_keys(retry.measurements, [:duration, :system_time])
    assert_keys(stop.measurements, [:duration, :system_time])
    assert start.measurements.system_time |> is_integer()
    assert retry.measurements.duration == 17
    assert stop.measurements.duration |> is_integer()

    request_keys = [
      :finish_reason,
      :http_status,
      :mode,
      :model,
      :operation,
      :provider,
      :reasoning,
      :request_id,
      :request_options,
      :request_started_system_time,
      :request_summary,
      :response_summary,
      :server,
      :streaming,
      :transport,
      :usage
    ]

    assert_keys(start.metadata, request_keys)
    assert_keys(retry.metadata, [:retry | request_keys])
    assert_keys(stop.metadata, request_keys)

    assert start.metadata.request_id == retry.metadata.request_id
    assert start.metadata.request_id == stop.metadata.request_id
    assert start.metadata.request_id == token_usage.metadata.request_id
    assert start.metadata.mode == :stream
    assert start.metadata.transport == :finch
    assert start.metadata.request_options.total_timeout == 30_000
    assert start.metadata.streaming == %{first_chunk_at: nil, time_to_first_chunk: nil}
    assert is_integer(stop.metadata.streaming.first_chunk_at)
    assert is_integer(stop.metadata.streaming.time_to_first_chunk)
    assert stop.metadata.streaming.time_to_first_chunk >= 0
    assert stop.metadata.finish_reason == :stop
    assert stop.metadata.usage == usage

    assert retry.metadata.retry == %{
             attempt: 1,
             next_attempt: 2,
             max_retries: 3,
             delay: 25,
             http_status: 429
           }

    assert token_usage.measurements == usage

    assert_keys(token_usage.metadata, [
      :mode,
      :model,
      :operation,
      :provider,
      :request_id,
      :transport
    ])

    refute Map.has_key?(start.metadata, :request_payload)
    refute Map.has_key?(stop.metadata, :response_payload)
  end

  test "preserves exception measurement and metadata shapes" do
    context =
      %LLMDB.Model{provider: :google, id: "gemini-2.5-pro"}
      |> ReqLLM.Telemetry.new_context([], operation: :object)
      |> ReqLLM.Telemetry.start_request(%{})

    error = ReqLLM.Error.API.Timeout.exception(kind: :total, timeout: 50)
    ReqLLM.Telemetry.exception_request(context, error, http_status: 504)

    exception =
      collect_events()
      |> single_event([:req_llm, :request, :exception])

    assert_keys(exception.measurements, [:duration, :system_time])

    assert_keys(exception.metadata, [
      :error,
      :finish_reason,
      :http_status,
      :mode,
      :model,
      :operation,
      :provider,
      :reasoning,
      :request_id,
      :request_options,
      :request_started_system_time,
      :request_summary,
      :response_summary,
      :server,
      :transport,
      :usage
    ])

    assert exception.metadata.finish_reason == :error
    assert exception.metadata.http_status == 504
    assert %ReqLLM.Error.API.Timeout{kind: :total, timeout: 50} = exception.metadata.error
    refute Map.has_key?(exception.metadata, :request_payload)
    refute Map.has_key?(exception.metadata, :response_payload)
  end

  test "reasoning detail events remain metadata-only" do
    context =
      %LLMDB.Model{
        provider: :openai,
        id: "gpt-5",
        capabilities: %{reasoning: %{enabled: true}}
      }
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"reasoning" => %{"effort" => "high"}})
      |> ReqLLM.Telemetry.observe_stream_chunk(ReqLLM.StreamChunk.thinking("private thought"))

    ReqLLM.Telemetry.stop_request(context, %{finish_reason: :stop}, finish_reason: :stop)

    events = collect_events()
    reasoning_start = single_event(events, [:req_llm, :reasoning, :start])
    reasoning_update = single_event(events, [:req_llm, :reasoning, :update])
    reasoning_stop = single_event(events, [:req_llm, :reasoning, :stop])

    assert_keys(reasoning_start.measurements, [:system_time])
    assert_keys(reasoning_update.measurements, [:system_time])
    assert_keys(reasoning_stop.measurements, [:duration, :system_time])

    Enum.each([reasoning_start, reasoning_update, reasoning_stop], fn event ->
      assert_keys(event.metadata, [
        :milestone,
        :mode,
        :model,
        :operation,
        :provider,
        :reasoning,
        :request_id,
        :transport
      ])

      assert_keys(event.metadata.reasoning, [
        :channel,
        :content_bytes,
        :effective?,
        :effective_budget_tokens,
        :effective_effort,
        :effective_mode,
        :reasoning_tokens,
        :requested?,
        :requested_budget_tokens,
        :requested_effort,
        :requested_mode,
        :returned_content?,
        :supported?
      ])

      refute inspect(event.metadata) =~ "private thought"
      refute Map.has_key?(event.metadata, :request_payload)
      refute Map.has_key?(event.metadata, :response_payload)
    end)
  end

  test "malformed tool argument diagnostics preserve their redacted shape" do
    accumulator =
      ChunkAccumulator.new()
      |> ChunkAccumulator.push(%ReqLLM.StreamChunk{
        type: :tool_call,
        name: "get_secret",
        arguments: %{},
        metadata: %{id: "call_secret", index: 0}
      })
      |> ChunkAccumulator.push(%ReqLLM.StreamChunk{
        type: :meta,
        metadata: %{
          tool_call_args: %{index: 0, fragment: ~s({"token":"private-value")}
        }
      })

    capture_log(fn -> ChunkAccumulator.finalize_tool_calls_for_response(accumulator) end)

    event =
      collect_events()
      |> single_event([:req_llm, :tool_call_args_lost])

    assert event.measurements == %{count: 1}
    assert_keys(event.metadata, [:reason, :tool_call_id, :tool_name])
    assert event.metadata.tool_name == "get_secret"
    assert event.metadata.tool_call_id == "call_secret"
    assert event.metadata.reason == :json_decode_error
    refute inspect(event) =~ "private-value"
  end

  defp collect_events(acc \\ []) do
    receive do
      {:telemetry_contract_event, name, measurements, metadata} ->
        collect_events([%{name: name, measurements: measurements, metadata: metadata} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp single_event(events, name) do
    [event] = Enum.filter(events, &(&1.name == name))
    event
  end

  defp assert_keys(map, expected) do
    assert Enum.sort(Map.keys(map)) == Enum.sort(expected)
  end
end
