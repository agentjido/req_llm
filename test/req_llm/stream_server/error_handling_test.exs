defmodule ReqLLM.StreamServer.ErrorHandlingTest do
  @moduledoc """
  Unit tests for StreamServer error handling and cleanup behavior.

  Tests graceful degradation, task crash recovery, malformed data handling,
  and proper resource cleanup during cancellation.

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "error handling and cleanup" do
    test "handles HTTP task crash gracefully" do
      server = start_server()
      task = mock_http_task(server)

      Process.exit(task.pid, :kill)
      :timer.sleep(20)

      assert Process.alive?(server)

      assert {:error, _} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "cancellation kills HTTP task and cleans up" do
      server = start_server()
      task = mock_http_task(server)

      assert Process.alive?(task.pid)

      assert :ok = StreamServer.cancel(server)

      :timer.sleep(20)

      refute Process.alive?(task.pid)
    end

    test "handles malformed SSE data gracefully" do
      server = start_server()
      _task = mock_http_task(server)

      malformed_data = "invalid sse data without proper format\n\n"
      assert :ok = GenServer.call(server, {:http_event, {:data, malformed_data}})

      Task.start(fn ->
        :timer.sleep(100)
        GenServer.call(server, {:http_event, :done})
      end)

      assert :halt = StreamServer.next(server, 200)

      StreamServer.cancel(server)
    end
  end
end
