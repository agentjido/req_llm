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
      task_ref = Process.monitor(task.pid)

      Process.exit(task.pid, :kill)
      assert_receive {:DOWN, ^task_ref, :process, task_pid, :killed} when task_pid == task.pid

      assert Process.alive?(server)

      assert {:error, _} = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "cancellation kills HTTP task and cleans up" do
      server = start_server()
      task = mock_http_task(server)
      task_ref = Process.monitor(task.pid)

      assert Process.alive?(task.pid)

      assert :ok = StreamServer.cancel(server)

      assert_receive {:DOWN, ^task_ref, :process, task_pid, _reason} when task_pid == task.pid
      refute Process.alive?(task.pid)
    end

    test "handles malformed SSE data gracefully" do
      server = start_server()
      _task = mock_http_task(server)

      malformed_data = "invalid sse data without proper format\n\n"
      assert :ok = GenServer.call(server, {:http_event, {:data, malformed_data}})

      next_task = Task.async(fn -> StreamServer.next(server, 200) end)
      assert :ok = await_waiting_callers(server, [:next])
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert :halt = Task.await(next_task)

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
      assert error.retryable == true

      StreamServer.cancel(server)
    end

    test "preserves an HTTP error after the response completes" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 500}})

      error_json = Jason.encode!(%{"error" => %{"message" => "Internal server error"}})
      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 500
      assert error.reason == "Internal server error"
      assert error.response_body["message"] == "Internal server error"

      StreamServer.cancel(server)
    end

    test "returns an HTTP error when a failed response has no body" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 503}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 503
      assert error.reason == "HTTP 503"
      assert error.response_body == nil
      assert error.retryable == true

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
      assert error.retryable == false

      StreamServer.cancel(server)
    end
  end
end
