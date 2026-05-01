defmodule ReqLLM.StreamServer.MetadataTest do
  @moduledoc """
  Unit tests for StreamServer metadata extraction and completion handling.

  Tests metadata accumulation from HTTP events (status, headers) and
  completion signaling via both [DONE] SSE events and :done HTTP events.

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "metadata and completion handling" do
    test "extracts and returns metadata on completion" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 200}})
      assert :ok = GenServer.call(server, {:http_event, {:headers, [{"x-custom", "value"}]}})

      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.status == 200
      assert metadata.headers == [{"x-custom", "value"}]

      StreamServer.cancel(server)
    end

    test "preserves total_tokens from usage metadata" do
      server = start_server()
      _task = mock_http_task(server)

      usage = %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 42}
      payload = Jason.encode!(%{"usage" => usage})

      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.usage.total_tokens == 42

      StreamServer.cancel(server)
    end

    test "await_metadata blocks until completion" do
      server = start_server()
      _task = mock_http_task(server)

      metadata_task =
        Task.async(fn ->
          StreamServer.await_metadata(server, 200)
        end)

      :timer.sleep(50)
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, metadata} = Task.await(metadata_task)
      assert is_map(metadata)

      StreamServer.cancel(server)
    end

    test "await_metadata returns error on stream failure" do
      server = start_server()
      _task = mock_http_task(server)

      error_reason = {:request_failed, "Network error"}
      assert :ok = GenServer.call(server, {:http_event, {:error, error_reason}})

      assert {:error, ^error_reason} = StreamServer.await_metadata(server, 100)

      StreamServer.cancel(server)
    end

    test "stops after normal HTTP task completion once halt and metadata are delivered" do
      server = start_server()
      task = Task.async(fn -> Process.sleep(20) end)

      StreamServer.attach_http_task(server, task.pid)

      next_task = Task.async(fn -> StreamServer.next(server, 200) end)
      metadata_task = Task.async(fn -> StreamServer.await_metadata(server, 200) end)

      assert :halt = Task.await(next_task)
      assert {:ok, metadata} = Task.await(metadata_task)
      assert metadata.finish_reason == :incomplete

      assert_receive {:EXIT, ^server, :normal}, 200
      refute Process.alive?(server)
    end

    test "terminal? flag from provider meta flips finish_reason to :stop" do
      server = start_server()
      _task = mock_http_task(server)

      payload = Jason.encode!(%{"event" => "terminal"})
      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :stop
      refute Map.has_key?(metadata, :terminal?)

      StreamServer.cancel(server)
    end

    test "terminal? flag from provider meta completes without transport done" do
      server = start_server()
      _task = mock_http_task(server)

      payload = Jason.encode!(%{"event" => "terminal"})
      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :stop
      refute Map.has_key?(metadata, :terminal?)

      StreamServer.cancel(server)
    end

    test "explicit finish_reason from provider wins over terminal? fallback" do
      server = start_server()
      _task = mock_http_task(server)

      finish_payload = Jason.encode!(%{"choices" => [%{"finish_reason" => "length"}]})
      terminal_payload = Jason.encode!(%{"event" => "terminal"})

      StreamServer.http_event(server, {:data, "data: #{finish_payload}\n\n"})
      StreamServer.http_event(server, {:data, "data: #{terminal_payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :length

      StreamServer.cancel(server)
    end
  end
end
