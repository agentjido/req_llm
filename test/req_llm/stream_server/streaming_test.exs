defmodule ReqLLM.StreamServer.StreamingTest do
  @moduledoc """
  StreamServer streaming behavior tests.

  Covers:
  - Backpressure handling
  - SSE edge cases (large events, incomplete events, multi-line events)
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
    test "applies backpressure when queue exceeds high_watermark" do
      server = start_server(high_watermark: 2)
      _task = mock_http_task(server)

      for i <- 1..5 do
        sse_data = ~s(data: {"choices": [{"delta": {"content": "#{i}"}}]}\n\n)
        GenServer.call(server, {:http_event, {:data, sse_data}})
      end

      assert {:ok, chunk1} = StreamServer.next(server, 100)
      assert chunk1.text == "1"

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2.text == "2"

      StreamServer.cancel(server)
    end

    test "resumes processing after queue drains below watermark" do
      server = start_server(high_watermark: 1)
      _task = mock_http_task(server)

      sse_data1 = ~s(data: {"choices": [{"delta": {"content": "First"}}]}\n\n)
      sse_data2 = ~s(data: {"choices": [{"delta": {"content": "Second"}}]}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data1}})

      data_task =
        Task.async(fn ->
          GenServer.call(server, {:http_event, {:data, sse_data2}})
        end)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "First"

      assert :ok = Task.await(data_task)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Second"

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

  describe "timeout handling" do
    test "next/2 respects timeout parameter" do
      server = start_server()
      _task = mock_http_task(server)

      start_time = :os.system_time(:millisecond)

      catch_exit do
        StreamServer.next(server, 50)
      end

      elapsed = :os.system_time(:millisecond) - start_time

      assert elapsed >= 1000
      assert elapsed < 1200

      StreamServer.cancel(server)
    end

    test "await_metadata/2 respects timeout parameter" do
      server = start_server()
      _task = mock_http_task(server)

      start_time = :os.system_time(:millisecond)

      catch_exit do
        StreamServer.await_metadata(server, 50)
      end

      elapsed = :os.system_time(:millisecond) - start_time

      assert elapsed >= 1000
      assert elapsed < 1200

      StreamServer.cancel(server)
    end
  end
end
