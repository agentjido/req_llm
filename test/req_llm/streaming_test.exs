defmodule ReqLLM.StreamingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Streaming}

  defmodule FailingHttpProvider do
    def attach_stream(_model, _context, _opts, _finch_name), do: {:error, :boom}
  end

  defmodule FailingWebSocketProvider do
    def stream_transport(_model, _opts), do: :websocket
    def attach_websocket_stream(_model, _context, _opts), do: {:error, :boom}
  end

  test "wraps HTTP transport startup failures" do
    {:ok, context} = Context.normalize("Hello")
    model = %LLMDB.Model{provider: :test, id: "test"}

    assert {:error, {:http_streaming_failed, {:provider_build_failed, :boom}}} =
             Streaming.start_stream(FailingHttpProvider, model, context, [])
  end

  test "wraps websocket transport startup failures" do
    {:ok, context} = Context.normalize("Hello")
    model = %LLMDB.Model{provider: :test, id: "test"}

    assert {:error, {:websocket_streaming_failed, {:provider_build_failed, :boom}}} =
             Streaming.start_stream(FailingWebSocketProvider, model, context, [])
  end
end
