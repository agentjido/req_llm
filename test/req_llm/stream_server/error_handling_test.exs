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

    test "detects HTTP error status codes and returns error instead of parsing as SSE" do
      server = start_server()
      _task = mock_http_task(server)

      # Send 401 status
      assert :ok = GenServer.call(server, {:http_event, {:status, 401}})

      # Send error JSON response body
      error_json =
        Jason.encode!(%{
          "error" => %{
            "type" => "authentication_error",
            "message" => "invalid x-api-key"
          }
        })

      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})

      # Should get error, not attempt to parse as SSE
      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 401
      assert error.reason == "invalid x-api-key"
      assert error.response_body["type"] == "authentication_error"

      StreamServer.cancel(server)
    end

    test "detects 5xx server errors" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 500}})

      error_json = Jason.encode!(%{"error" => %{"message" => "Internal server error"}})
      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})

      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 500
      assert error.reason == "Internal server error"

      StreamServer.cancel(server)
    end

    test "handles non-JSON error responses" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 404}})
      assert :ok = GenServer.call(server, {:http_event, {:data, "Not Found"}})

      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 404
      assert error.reason == "HTTP 404"
      assert error.response_body == "Not Found"

      StreamServer.cancel(server)
    end
  end
end
