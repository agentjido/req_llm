defmodule ReqLLM.StreamServer.StreamingTest do
  @moduledoc """
  StreamServer streaming behavior tests.

  Covers:
  - Backpressure handling
  - SSE edge cases (large events, incomplete events, multi-line events)
  - SSE buffer flushing on stream finalization
  - Default finish_reason metadata
  - Timeout handling

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "backpressure handling" do
    test "bounds queued chunks and fixture data until consumer demand resumes" do
      server = start_server(high_watermark: 1, fixture_path: "unused-stream-fixture.json")
      parent = self()

      events =
        for text <- ["one", "two", "three"] do
          {text, ~s(data: {"choices": [{"delta": {"content": "#{text}"}}]}\n\n)}
        end

      producer =
        Task.async(fn ->
          Enum.each(events, fn {text, event} ->
            send(parent, {:producer_sending, text})
            :ok = StreamServer.http_event(server, {:data, event})
            send(parent, {:producer_acknowledged, text})
          end)
        end)

      expected_raw_bytes =
        Enum.reduce(events, 0, fn {text, event}, raw_bytes ->
          assert_receive {:producer_sending, ^text}
          expected_raw_bytes = raw_bytes + byte_size(event)
          assert :ok = wait_for_backpressure(server, expected_raw_bytes)
          refute_receive {:producer_acknowledged, ^text}, 25

          assert {:ok, chunk} = StreamServer.next(server, 100)
          assert chunk.text == text
          assert_receive {:producer_acknowledged, ^text}

          expected_raw_bytes
        end)

      assert expected_raw_bytes ==
               Enum.sum(Enum.map(events, fn {_text, event} -> byte_size(event) end))

      assert :ok = Task.await(producer)
      assert :ok = StreamServer.http_event(server, :done)
      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "cancellation releases a suspended producer" do
      server = start_server(high_watermark: 1)
      first = ~s(data: {"choices": [{"delta": {"content": "first"}}]}\n\n)
      second = ~s(data: {"choices": [{"delta": {"content": "second"}}]}\n\n)
      first_producer = Task.async(fn -> StreamServer.http_event(server, {:data, first}) end)

      assert :ok = wait_for_backpressure(server)

      second_producer = Task.async(fn -> StreamServer.http_event(server, {:data, second}) end)
      assert :ok = wait_for_pending_http_call(server)

      assert :ok = StreamServer.cancel(server)
      assert :ok = Task.await(first_producer)
      assert :ok = Task.await(second_producer)
    end

    test "consumer termination releases a suspended producer" do
      server = start_server(high_watermark: 1)

      consumer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert :ok = StreamServer.monitor_consumer(server, consumer)

      event = ~s(data: {"choices": [{"delta": {"content": "blocked"}}]}\n\n)
      producer = Task.async(fn -> StreamServer.http_event(server, {:data, event}) end)
      server_ref = Process.monitor(server)

      assert :ok = wait_for_backpressure(server)
      Process.exit(consumer, :cancelled)

      assert :ok = Task.await(producer)
      assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}
    end

    test "telemetry deferral cannot bypass the watermark" do
      server = start_server(high_watermark: 2)
      :sys.replace_state(server, &%{&1 | telemetry_pending?: true})

      event = """
      data: {"choices": [{"delta": {"content": "one"}}]}

      data: {"choices": [{"delta": {"content": "two"}}]}

      data: {"choices": [{"delta": {"content": "three"}}]}

      """

      producer = Task.async(fn -> StreamServer.http_event(server, {:data, event}) end)

      assert :ok = wait_for_telemetry_backpressure(server)
      assert nil == Task.yield(producer, 25)

      assert :ok = StreamServer.set_telemetry_context(server, nil)
      assert nil == Task.yield(producer, 25)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "one"
      assert nil == Task.yield(producer, 25)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "two"
      assert :ok = Task.await(producer)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "three"

      StreamServer.cancel(server)
    end
  end

  describe "SSE edge cases" do
    test "handles very large SSE event" do
      server = start_server()

      large_content = String.duplicate("x", 200_000)
      large_json = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => large_content}}]})
      sse_event = "data: #{large_json}\n\n"

      StreamServer.http_event(server, {:data, sse_event})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == large_content
    end

    test "handles incomplete event at stream end" do
      server = start_server()

      StreamServer.http_event(server, {:data, "data: {\"partial"})
      StreamServer.http_event(server, :done)

      assert :halt = StreamServer.next(server, 100)
    end

    test "handles multiple incomplete fragments before completion" do
      server = start_server()

      StreamServer.http_event(server, {:data, "data: {\"cho"})
      StreamServer.http_event(server, {:data, "ices\": [{\"del"})
      StreamServer.http_event(server, {:data, "ta\": {\"content\""})
      StreamServer.http_event(server, {:data, ": \"hello\"}}"})
      StreamServer.http_event(server, {:data, "]}\n\n"})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "hello"
    end

    test "handles SSE event with multiple data: lines" do
      server = start_server()

      sse_event =
        ~s(data: {"choices": [{"delta": \n) <>
          ~s(data: {"content": "multiline content"}}]}\n\n)

      StreamServer.http_event(server, {:data, sse_event})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "multiline content"
    end
  end

  describe "SSE buffer flushing on finalize" do
    test "flushes buffered event missing trailing blank line on :done" do
      server = start_server()

      sse_without_terminator = ~s(data: {"choices": [{"delta": {"content": "buffered"}}]}\n)
      StreamServer.http_event(server, {:data, sse_without_terminator})
      StreamServer.http_event(server, :done)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "buffered"
      assert :halt = StreamServer.next(server, 100)
    end

    test "flushes buffered event split across chunks without trailing blank line" do
      server = start_server()

      StreamServer.http_event(server, {:data, "data: {\"cho"})

      StreamServer.http_event(
        server,
        {:data, "ices\": [{\"delta\": {\"content\": \"split\"}}]}\n"}
      )

      StreamServer.http_event(server, :done)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "split"
      assert :halt = StreamServer.next(server, 100)
    end

    test "noop when protocol state is empty at finalize" do
      server = start_server()

      sse_data = ~s(data: {"choices": [{"delta": {"content": "complete"}}]}\n\n)
      StreamServer.http_event(server, {:data, sse_data})
      StreamServer.http_event(server, :done)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "complete"
      assert :halt = StreamServer.next(server, 100)
    end
  end

  describe "finish_reason metadata" do
    test "defaults to :stop when provider sends termination event without finish_reason" do
      server = start_server()

      sse_data = ~s(data: {"choices": [{"delta": {"content": "hi"}}]}\n\n)
      done_event = "data: [DONE]\n\n"

      StreamServer.http_event(server, {:data, sse_data})
      StreamServer.http_event(server, {:data, done_event})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      assert metadata.finish_reason == :stop
    end

    test "defaults to :stop when buffered done event is missing trailing blank line" do
      server = start_server()

      StreamServer.http_event(server, {:data, "data: [DONE]\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      assert metadata.finish_reason == :stop
    end

    test "sets finish_reason to :incomplete when stream ends without termination event" do
      server = start_server()

      sse_data = ~s(data: {"choices": [{"delta": {"content": "hi"}}]}\n\n)
      StreamServer.http_event(server, {:data, sse_data})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      assert metadata.finish_reason == :incomplete
    end

    test "preserves provider-supplied finish_reason" do
      server = start_server()

      sse_data = ~s(data: {"choices": [{"delta": {"content": "hi"}}]}\n\n)
      finish_json = Jason.encode!(%{"choices" => [%{"finish_reason" => "tool_use"}]})
      finish_event = "data: #{finish_json}\n\n"

      StreamServer.http_event(server, {:data, sse_data})
      StreamServer.http_event(server, {:data, finish_event})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
      assert metadata.finish_reason == "tool_use"
    end
  end

  describe "timeout handling" do
    test "next/2 respects timeout parameter" do
      server = start_server()
      _task = mock_http_task(server)

      start_time = :os.system_time(:millisecond)

      assert {:error, :timeout} = StreamServer.next(server, 50)

      elapsed = :os.system_time(:millisecond) - start_time

      assert elapsed >= 50
      assert elapsed < 250

      StreamServer.cancel(server)
    end

    test "await_metadata/2 respects timeout parameter" do
      server = start_server()
      _task = mock_http_task(server)

      start_time = :os.system_time(:millisecond)

      assert {:error, :timeout} = StreamServer.await_metadata(server, 50)

      elapsed = :os.system_time(:millisecond) - start_time

      assert elapsed >= 50
      assert elapsed < 250

      StreamServer.cancel(server)
    end

    test "await_metadata/2 resets a finite timeout on semantic progress" do
      server = start_server()
      _task = mock_http_task(server)

      metadata_task = Task.async(fn -> StreamServer.await_metadata(server, 250) end)

      Process.sleep(150)

      StreamServer.http_event(
        server,
        {:data, ~s(data: {"choices": [{"delta": {"content": "one"}}]}\n\n)}
      )

      Process.sleep(150)

      StreamServer.http_event(
        server,
        {:data, ~s(data: {"choices": [{"delta": {"content": "two"}}]}\n\n)}
      )

      Process.sleep(150)
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = Task.await(metadata_task, 500)
      assert metadata.finish_reason == :incomplete

      StreamServer.cancel(server)
    end

    test "next/2 returns structured timeout when transport error arrives late" do
      server = start_server()
      _task = mock_http_task(server)

      timeout_task =
        Task.async(fn ->
          StreamServer.next(server, 50)
        end)

      spawn(fn ->
        :timer.sleep(1200)
        GenServer.call(server, {:http_event, {:error, :transport_timeout}})
      end)

      assert {:error, :timeout} = Task.await(timeout_task, 500)

      :timer.sleep(1250)

      assert {:error, :transport_timeout} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end
  end

  defp wait_for_backpressure(server, expected_raw_bytes \\ nil, attempts \\ 100)

  defp wait_for_backpressure(_server, _expected_raw_bytes, 0) do
    flunk("StreamServer did not apply backpressure")
  end

  defp wait_for_backpressure(server, expected_raw_bytes, attempts) do
    state = :sys.get_state(server)

    raw_bytes_match? = is_nil(expected_raw_bytes) or state.raw_bytes == expected_raw_bytes

    if state.blocked_http_event && :queue.len(state.queue) == 1 && raw_bytes_match? do
      :ok
    else
      Process.sleep(10)
      wait_for_backpressure(server, expected_raw_bytes, attempts - 1)
    end
  end

  defp wait_for_pending_http_call(server, attempts \\ 100)

  defp wait_for_pending_http_call(_server, 0) do
    flunk("StreamServer did not retain the pending HTTP call")
  end

  defp wait_for_pending_http_call(server, attempts) do
    state = :sys.get_state(server)

    if :queue.len(state.pending_http_calls) == 1 do
      :ok
    else
      Process.sleep(10)
      wait_for_pending_http_call(server, attempts - 1)
    end
  end

  defp wait_for_telemetry_backpressure(server, attempts \\ 100)

  defp wait_for_telemetry_backpressure(_server, 0) do
    flunk("StreamServer did not backpressure deferred telemetry events")
  end

  defp wait_for_telemetry_backpressure(server, attempts) do
    state = :sys.get_state(server)

    if state.blocked_http_event && length(state.pending_http_events) == 1 do
      :ok
    else
      Process.sleep(10)
      wait_for_telemetry_backpressure(server, attempts - 1)
    end
  end
end
