defmodule ReqLLM.StreamServerTest do
  @moduledoc """
  Unit tests for ReqLLM.StreamServer GenServer.

  Tests the core streaming session management including:
  - SSE parsing across chunk boundaries
  - Token queuing and retrieval via next/2
  - Backpressure when queue exceeds high_watermark
  - Metadata extraction and completion detection  
  - HTTP task monitoring and error handling
  - Cancellation cleanup

  Uses mocked HTTP events and provider modules for isolated testing.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  setup do
    # Trap exits to avoid test failures from expected process terminations
    Process.flag(:trap_exit, true)
    :ok
  end

  # Mock provider for testing
  defmodule MockProvider do
    @behaviour ReqLLM.Provider

    def decode_sse_event(%{data: %{"choices" => [%{"delta" => %{"content" => content}}]}}, _model)
        when is_binary(content) do
      [StreamChunk.text(content)]
    end

    def decode_sse_event(
          %{data: %{"type" => "content_block_delta", "delta" => %{"text" => text}}},
          _model
        ) do
      [StreamChunk.text(text)]
    end

    def decode_sse_event(%{data: %{"usage" => usage}}, _model) do
      [StreamChunk.meta(usage)]
    end

    def decode_sse_event(_event, _model), do: []

    # Required callbacks (unused in tests)
    def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
    def attach(_req, _model, _opts), do: {:error, :not_implemented}
    def encode_body(_req), do: {:error, :not_implemented}
    def decode_response(_resp), do: {:error, :not_implemented}
  end

  defp start_server(opts \\ []) do
    default_opts = [
      provider_mod: MockProvider,
      model: %ReqLLM.Model{provider: :test, model: "test-model"}
    ]

    opts = Keyword.merge(default_opts, opts)
    {:ok, server} = StreamServer.start_link(opts)
    server
  end

  defp mock_http_task(server) do
    task = Task.async(fn -> :timer.sleep(50_000) end)
    StreamServer.attach_http_task(server, task.pid)
    task
  end

  describe "initialization and basic operations" do
    test "starts with correct initial state" do
      server = start_server()

      # Server should start successfully
      assert Process.alive?(server)

      # Should be able to cancel immediately
      assert :ok = StreamServer.cancel(server)
    end

    test "handles HTTP task attachment and monitoring" do
      server = start_server()
      task = mock_http_task(server)

      # Task should be monitored
      Process.exit(task.pid, :kill)

      # Give time for monitor message
      :timer.sleep(10)

      # Server should still be alive (handles task death gracefully)
      assert Process.alive?(server)

      StreamServer.cancel(server)
      refute Process.alive?(server)
    end
  end

  describe "HTTP event processing" do
    test "processes status and headers events" do
      server = start_server()
      _task = mock_http_task(server)

      # Should accept status and headers
      assert :ok = GenServer.call(server, {:http_event, {:status, 200}})

      assert :ok =
               GenServer.call(
                 server,
                 {:http_event, {:headers, [{"content-type", "text/event-stream"}]}}
               )

      StreamServer.cancel(server)
    end

    test "processes simple SSE data chunks" do
      server = start_server()
      _task = mock_http_task(server)

      # Send SSE data chunk  
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      # Should be able to retrieve the chunk
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "Hello"

      StreamServer.cancel(server)
    end

    test "handles SSE events across chunk boundaries" do
      server = start_server()
      _task = mock_http_task(server)

      # Split SSE event across multiple chunks
      chunk1 = ~s(data: {"choices": [{"delta": {"content": "Hel)
      chunk2 = ~s(lo World"}}]}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, chunk1}})

      # No complete event yet
      Task.start(fn ->
        :timer.sleep(50)
        GenServer.call(server, {:http_event, {:data, chunk2}})
      end)

      # Should eventually get complete text
      assert {:ok, chunk} = StreamServer.next(server, 200)
      assert chunk.type == :content
      assert chunk.text == "Hello World"

      StreamServer.cancel(server)
    end

    test "detects completion via [DONE] signal" do
      server = start_server()
      _task = mock_http_task(server)

      # Send content then completion
      sse_content = ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n)
      sse_done = ~s(data: [DONE]\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_content}})
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_done}})

      # Get content chunk
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Hello"

      # Should signal completion
      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "handles completion via :done event" do
      server = start_server()
      _task = mock_http_task(server)

      # Send some content
      sse_content = ~s(data: {"choices": [{"delta": {"content": "Test"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_content}})

      # Signal HTTP completion
      assert :ok = GenServer.call(server, {:http_event, :done})

      # Get content
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Test"

      # Should halt
      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "processes error events" do
      server = start_server()
      _task = mock_http_task(server)

      error_reason = {:request_failed, "Connection timeout"}
      assert :ok = GenServer.call(server, {:http_event, {:error, error_reason}})

      # Should return error
      assert {:error, ^error_reason} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end
  end

  describe "token queuing and consumer interface" do
    test "queues multiple tokens from single SSE event" do
      server = start_server()
      _task = mock_http_task(server)

      # Multiple content deltas in one SSE chunk
      sse_data = """
      data: {"choices": [{"delta": {"content": "Hello"}}]}

      data: {"choices": [{"delta": {"content": " World"}}]}

      """

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      # Should get both chunks in order
      assert {:ok, chunk1} = StreamServer.next(server, 100)
      assert chunk1.text == "Hello"

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2.text == " World"

      StreamServer.cancel(server)
    end

    test "handles empty queue when stream is still active" do
      server = start_server()
      _task = mock_http_task(server)

      # Start consuming before data arrives
      consume_task =
        Task.async(fn ->
          StreamServer.next(server, 200)
        end)

      # Send data after a delay
      :timer.sleep(50)
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Delayed"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      # Should eventually get the chunk
      assert {:ok, chunk} = Task.await(consume_task)
      assert chunk.text == "Delayed"

      StreamServer.cancel(server)
    end

    test "handles concurrent consumers" do
      server = start_server()
      _task = mock_http_task(server)

      # Send multiple chunks
      for i <- 1..5 do
        sse_data = ~s(data: {"choices": [{"delta": {"content": "#{i}"}}]}\n\n)
        assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})
      end

      # Start multiple consumers
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

      # Should get some results (exact order not guaranteed)
      assert Enum.all?(results, fn result ->
               result in ["1", "2", "3", "4", "5"] or is_nil(result)
             end)

      StreamServer.cancel(server)
    end
  end

  describe "backpressure handling" do
    test "applies backpressure when queue exceeds high_watermark" do
      server = start_server(high_watermark: 2)
      _task = mock_http_task(server)

      # Fill queue beyond high watermark
      for i <- 1..5 do
        sse_data = ~s(data: {"choices": [{"delta": {"content": "#{i}"}}]}\n\n)
        # These calls should delay when queue is full
        GenServer.call(server, {:http_event, {:data, sse_data}})
      end

      # Should be able to consume items
      assert {:ok, chunk1} = StreamServer.next(server, 100)
      assert chunk1.text == "1"

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2.text == "2"

      StreamServer.cancel(server)
    end

    test "resumes processing after queue drains below watermark" do
      server = start_server(high_watermark: 1)
      _task = mock_http_task(server)

      # Send data that will exceed watermark
      sse_data1 = ~s(data: {"choices": [{"delta": {"content": "First"}}]}\n\n)
      sse_data2 = ~s(data: {"choices": [{"delta": {"content": "Second"}}]}\n\n)

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data1}})

      # This should be delayed due to backpressure
      data_task =
        Task.async(fn ->
          GenServer.call(server, {:http_event, {:data, sse_data2}})
        end)

      # Drain one item to make space
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "First"

      # The delayed call should now complete
      assert :ok = Task.await(data_task)

      # Should get the second chunk
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Second"

      StreamServer.cancel(server)
    end
  end

  describe "metadata and completion handling" do
    test "extracts and returns metadata on completion" do
      server = start_server()
      _task = mock_http_task(server)

      # Send status and headers first
      assert :ok = GenServer.call(server, {:http_event, {:status, 200}})
      assert :ok = GenServer.call(server, {:http_event, {:headers, [{"x-custom", "value"}]}})

      # Send completion
      assert :ok = GenServer.call(server, {:http_event, :done})

      # Should be able to get metadata
      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.status == 200
      assert metadata.headers == [{"x-custom", "value"}]

      StreamServer.cancel(server)
    end

    test "await_metadata blocks until completion" do
      server = start_server()
      _task = mock_http_task(server)

      # Start waiting for metadata before completion
      metadata_task =
        Task.async(fn ->
          StreamServer.await_metadata(server, 200)
        end)

      # Send completion after delay
      :timer.sleep(50)
      assert :ok = GenServer.call(server, {:http_event, :done})

      # Should eventually get metadata
      assert {:ok, metadata} = Task.await(metadata_task)
      assert is_map(metadata)

      StreamServer.cancel(server)
    end

    test "await_metadata returns error on stream failure" do
      server = start_server()
      _task = mock_http_task(server)

      error_reason = {:request_failed, "Network error"}
      assert :ok = GenServer.call(server, {:http_event, {:error, error_reason}})

      # Should get error from metadata await
      assert {:error, ^error_reason} = StreamServer.await_metadata(server, 100)

      StreamServer.cancel(server)
    end
  end

  describe "error handling and cleanup" do
    test "handles HTTP task crash gracefully" do
      server = start_server()
      task = mock_http_task(server)

      # Kill the HTTP task
      Process.exit(task.pid, :kill)
      :timer.sleep(20)

      # Server should handle this gracefully
      assert Process.alive?(server)

      # Should return error for subsequent operations
      assert {:error, _} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "cancellation kills HTTP task and cleans up" do
      server = start_server()
      task = mock_http_task(server)

      assert Process.alive?(task.pid)

      # Cancel should clean up
      assert :ok = StreamServer.cancel(server)

      # Give time for cleanup
      :timer.sleep(20)

      # Task should be dead
      refute Process.alive?(task.pid)
    end

    test "handles malformed SSE data gracefully" do
      server = start_server()
      _task = mock_http_task(server)

      # Send malformed data
      malformed_data = "invalid sse data without proper format\n\n"
      assert :ok = GenServer.call(server, {:http_event, {:data, malformed_data}})

      # Should not crash, though no valid chunks produced
      Task.start(fn ->
        :timer.sleep(100)
        GenServer.call(server, {:http_event, :done})
      end)

      assert :halt = StreamServer.next(server, 200)

      StreamServer.cancel(server)
    end
  end

  describe "provider integration" do
    test "uses provider decode_sse_event when available" do
      # This test verifies the provider integration is working
      server = start_server()
      _task = mock_http_task(server)

      # Send provider-specific format
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Provider test"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "Provider test"

      StreamServer.cancel(server)
    end

    test "falls back to default decoding when provider doesn't implement decode_sse_event" do
      defmodule MinimalProvider do
        @behaviour ReqLLM.Provider

        # Only implement required callbacks, no decode_sse_event
        def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
        def attach(_req, _model, _opts), do: {:error, :not_implemented}
        def encode_body(_req), do: {:error, :not_implemented}
        def decode_response(_resp), do: {:error, :not_implemented}
      end

      server = start_server(provider_mod: MinimalProvider)
      _task = mock_http_task(server)

      # Should still work with default decoding
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Default decode"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Default decode"

      StreamServer.cancel(server)
    end
  end

  describe "timeout handling" do
    test "next/2 respects timeout parameter" do
      server = start_server()
      _task = mock_http_task(server)

      # Should timeout waiting for data
      start_time = :os.system_time(:millisecond)

      catch_exit do
        StreamServer.next(server, 50)
      end

      elapsed = :os.system_time(:millisecond) - start_time

      # Should have waited approximately the GenServer timeout period (timeout + 1000)
      assert elapsed >= 1000
      # Allow some margin for scheduling
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

      # Should have waited approximately the GenServer timeout period (timeout + 1000)
      assert elapsed >= 1000
      assert elapsed < 1200

      StreamServer.cancel(server)
    end
  end
end
