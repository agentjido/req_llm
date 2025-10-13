defmodule ReqLLM.StreamServer.CoreTest do
  @moduledoc """
  Core StreamServer functionality tests.

  Covers:
  - Basic initialization and operations
  - HTTP event processing
  - Token queuing and consumer interface

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "initialization and basic operations" do
    test "starts with correct initial state" do
      server = start_server()

      assert Process.alive?(server)

      assert :ok = StreamServer.cancel(server)
    end

    test "handles HTTP task attachment and monitoring" do
      server = start_server()
      task = mock_http_task(server)

      Process.exit(task.pid, :kill)

      :timer.sleep(10)

      assert Process.alive?(server)

      StreamServer.cancel(server)
      refute Process.alive?(server)
    end
  end

  describe "HTTP event processing" do
    test "processes status and headers events" do
      server = start_server([])
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 200}})

      assert :ok =
               GenServer.call(
                 server,
                 {:http_event, {:headers, [{"content-type", "text/event-stream"}]}}
               )

      StreamServer.cancel(server)
    end

    test "processes simple SSE data chunks" do
      server = start_server([])
      _task = mock_http_task(server)

      sse_data = ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "Hello"

      StreamServer.cancel(server)
    end

    test "handles SSE events across chunk boundaries" do
      server = start_server([])
      _task = mock_http_task(server)

      chunk1 = ~s(data: {"choices": [{"delta": {"content": "Hel)
      chunk2 = ~s(lo World"}}]}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, chunk1}})

      Task.start(fn ->
        :timer.sleep(50)
        GenServer.call(server, {:http_event, {:data, chunk2}})
      end)

      assert {:ok, chunk} = StreamServer.next(server, 200)
      assert chunk.type == :content
      assert chunk.text == "Hello World"

      StreamServer.cancel(server)
    end

    test "detects completion via [DONE] signal" do
      server = start_server([])
      _task = mock_http_task(server)

      sse_content = ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n)
      sse_done = ~s(data: [DONE]\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_content}})
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_done}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Hello"

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "handles completion via :done event" do
      server = start_server([])
      _task = mock_http_task(server)

      sse_content = ~s(data: {"choices": [{"delta": {"content": "Test"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_content}})

      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Test"

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "processes error events" do
      server = start_server([])
      _task = mock_http_task(server)

      error_reason = {:request_failed, "Connection timeout"}
      assert :ok = GenServer.call(server, {:http_event, {:error, error_reason}})

      assert {:error, ^error_reason} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end
  end

  describe "token queuing and consumer interface" do
    test "queues multiple tokens from single SSE event" do
      server = start_server()
      _task = mock_http_task(server)

      sse_data = """
      data: {"choices": [{"delta": {"content": "Hello"}}]}

      data: {"choices": [{"delta": {"content": " World"}}]}

      """

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk1} = StreamServer.next(server, 100)
      assert chunk1.text == "Hello"

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2.text == " World"

      StreamServer.cancel(server)
    end

    test "handles empty queue when stream is still active" do
      server = start_server()
      _task = mock_http_task(server)

      consume_task =
        Task.async(fn ->
          StreamServer.next(server, 200)
        end)

      :timer.sleep(50)
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Delayed"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = Task.await(consume_task)
      assert chunk.text == "Delayed"

      StreamServer.cancel(server)
    end

    test "handles concurrent consumers" do
      server = start_server()
      _task = mock_http_task(server)

      for i <- 1..5 do
        sse_data = ~s(data: {"choices": [{"delta": {"content": "#{i}"}}]}\n\n)
        assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})
      end

      consumers =
        for _ <- 1..3 do
          Task.async(fn ->
            case StreamServer.next(server, 100) do
              {:ok, chunk} -> chunk.text
              _ -> nil
            end
          end)
        end

      results = Task.await_many(consumers)

      assert Enum.all?(results, fn result ->
               result in ["1", "2", "3", "4", "5"] or is_nil(result)
             end)

      StreamServer.cancel(server)
    end
  end
end
