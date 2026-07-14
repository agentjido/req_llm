defmodule ReqLLM.StreamServer.ConcurrencyTest do
  @moduledoc """
  Unit tests for StreamServer concurrent consumer scenarios.

  Tests concurrent access patterns including multiple consumers,
  interleaved operations, backpressure under concurrency, and
  timeout handling.

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "concurrent consumers" do
    test "multiple concurrent consumers drain in order" do
      server = start_server()
      _task = mock_http_task(server)

      sse_data1 = ~s(data: {"choices": [{"delta": {"content": "first"}}]}\n\n)
      sse_data2 = ~s(data: {"choices": [{"delta": {"content": "second"}}]}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data1}})
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data2}})

      task1 = Task.async(fn -> StreamServer.next(server, 1000) end)
      task2 = Task.async(fn -> StreamServer.next(server, 1000) end)
      task3 = Task.async(fn -> StreamServer.next(server, 1000) end)

      assert :ok = GenServer.call(server, {:http_event, :done})

      results = Task.await_many([task1, task2, task3])

      ok_texts =
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, chunk} -> chunk.text end)
        |> Enum.sort()

      halt_count = Enum.count(results, &(&1 == :halt))

      assert ok_texts == ["first", "second"]
      assert halt_count == 1

      StreamServer.cancel(server)
    end

    test "interleaved next and await_metadata calls" do
      server = start_server()
      _task = mock_http_task(server)

      next_task = Task.async(fn -> StreamServer.next(server, 1000) end)
      metadata_task = Task.async(fn -> StreamServer.await_metadata(server, 1000) end)

      :timer.sleep(50)

      content_data = ~s(data: {"choices": [{"delta": {"content": "text"}}]}\n\n)
      usage_data = ~s(data: {"usage": {"prompt_tokens": 10, "completion_tokens": 32}}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, content_data}})
      assert :ok = GenServer.call(server, {:http_event, {:data, usage_data}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, chunk} = Task.await(next_task)
      assert chunk.text == "text"

      assert {:ok, metadata} = Task.await(metadata_task)
      assert metadata.status == nil
      assert metadata.headers == []
      assert get_in(metadata, [:usage, :total_tokens]) == 42

      StreamServer.cancel(server)
    end

    test "consumer demand releases a backpressured producer one chunk at a time" do
      server = start_server(high_watermark: 1)

      sse_data1 = ~s(data: {"choices": [{"delta": {"content": "one"}}]}\n\n)
      sse_data2 = ~s(data: {"choices": [{"delta": {"content": "two"}}]}\n\n)
      sse_data3 = ~s(data: {"choices": [{"delta": {"content": "three"}}]}\n\n)

      producer =
        Task.async(fn ->
          Enum.each([sse_data1, sse_data2, sse_data3], fn event ->
            :ok = StreamServer.http_event(server, {:data, event})
          end)

          StreamServer.http_event(server, :done)
        end)

      assert :ok = wait_for_backpressure(server)

      chunks =
        for expected <- ["one", "two", "three"] do
          consumer = Task.async(fn -> StreamServer.next(server, 1000) end)
          assert {:ok, chunk} = Task.await(consumer)
          assert chunk.text == expected

          if expected != "three" do
            assert :ok = wait_for_backpressure(server)
          end

          chunk.text
        end

      assert chunks == ["one", "two", "three"]
      assert :ok = Task.await(producer)
      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "handles consumer timeout while waiting" do
      server = start_server()
      _task = mock_http_task(server)

      timeout_task =
        Task.async(fn ->
          StreamServer.next(server, 50)
        end)

      result = Task.await(timeout_task, 500)

      assert {:error, :timeout} = result

      assert Process.alive?(server)

      StreamServer.cancel(server)
    end
  end

  defp wait_for_backpressure(server, attempts \\ 100)

  defp wait_for_backpressure(_server, 0) do
    flunk("StreamServer did not apply backpressure")
  end

  defp wait_for_backpressure(server, attempts) do
    state = :sys.get_state(server)

    if state.blocked_http_event && :queue.len(state.queue) == 1 do
      :ok
    else
      Process.sleep(10)
      wait_for_backpressure(server, attempts - 1)
    end
  end
end
