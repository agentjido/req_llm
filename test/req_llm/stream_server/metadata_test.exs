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
  end
end
