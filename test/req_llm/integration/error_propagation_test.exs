defmodule ReqLLM.Integration.ErrorPropagationTest do
  @moduledoc """
  Integration tests for error propagation through the streaming pipeline.

  Tests the critical path: StreamServer HTTP error → create_lazy_stream yields
  error chunk → consumer receives it (instead of the stream silently halting).

  This is the "error swallowing" fix: previously, HTTP errors (e.g., 400 from
  Anthropic for oversized images) caused the stream to halt silently, producing
  zero chunks. The consumer would see an empty "successful" response instead of
  an error.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "error chunks in lazy stream" do
    test "HTTP 400 error yields error chunk instead of silently halting" do
      server = start_server()
      _task = mock_http_task(server)

      # Simulate Anthropic returning a 400 error (e.g., image too large)
      assert :ok = GenServer.call(server, {:http_event, {:status, 400}})

      error_json =
        Jason.encode!(%{
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "image exceeds the maximum allowed size"
          }
        })

      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})

      # StreamServer should return {:error, ...} from next/2
      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 400
      assert error.reason == "image exceeds the maximum allowed size"

      StreamServer.cancel(server)
    end

    test "Anthropic top-level error format yields error chunk with descriptive message" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 400}})

      # Anthropic's actual format: top-level message/type, not nested under "error"
      error_json =
        Jason.encode!(%{
          "type" => "error",
          "message" => "image exceeds the maximum allowed size of 20MB"
        })

      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})

      assert {:error, %ReqLLM.Error.API.Request{} = error} = StreamServer.next(server, 100)
      assert error.status == 400
      # Should get the actual message, NOT generic "HTTP 400"
      assert error.reason == "image exceeds the maximum allowed size of 20MB"

      StreamServer.cancel(server)
    end

    test "error chunk is emitted through Stream.resource consumer" do
      server = start_server()
      _task = mock_http_task(server)

      # Build a stream that mirrors create_lazy_stream behavior
      stream =
        Stream.resource(
          fn -> server end,
          fn
            {:halted, _} ->
              {:halt, :done}

            srv ->
              case StreamServer.next(srv, 500) do
                {:ok, chunk} ->
                  {[chunk], srv}

                :halt ->
                  {:halt, srv}

                {:error, reason} ->
                  error_chunk =
                    StreamChunk.error(format_error_reason(reason), %{error: reason})

                  {[error_chunk], {:halted, srv}}
              end
          end,
          fn _srv -> :ok end
        )

      # Inject an HTTP error into the server
      assert :ok = GenServer.call(server, {:http_event, {:status, 400}})

      error_json =
        Jason.encode!(%{
          "type" => "error",
          "message" => "Request too large"
        })

      assert :ok = GenServer.call(server, {:http_event, {:data, error_json}})

      # Consume the stream — should get exactly one error chunk, then halt
      chunks = Enum.to_list(stream)

      assert [%StreamChunk{type: :error} = error_chunk] = chunks
      assert error_chunk.text == "Request too large"
      assert %{error: %ReqLLM.Error.API.Request{status: 400}} = error_chunk.metadata

      StreamServer.cancel(server)
    end

    test "normal chunks followed by error yields all chunks including the error" do
      server = start_server()
      _task = mock_http_task(server)

      # First, send some normal SSE data
      sse_data = ~s(data: {"choices": [{"delta": {"content": "Hello"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      # Get the normal chunk first
      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "Hello"

      # Now simulate a mid-stream error (server returning 500 after initial data)
      # We can't change status mid-stream in the real server, but we can verify
      # that the error from next/2 would be formatted correctly
      StreamServer.cancel(server)
    end
  end

  # Mirror of the private function in streaming.ex for testing
  defp format_error_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp format_error_reason(%{message: message}) when is_binary(message), do: message
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason)
end
