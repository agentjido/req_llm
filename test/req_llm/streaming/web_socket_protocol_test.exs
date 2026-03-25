defmodule ReqLLM.Streaming.WebSocketProtocolTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Streaming.WebSocketProtocol

  test "parses json websocket message into stream event" do
    message = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello"})

    assert {:ok, [%{event: "response.output_text.delta", data: %{"delta" => "Hello"}}], ""} =
             WebSocketProtocol.parse_message(message, "")
  end

  test "identifies terminal response messages" do
    message = Jason.encode!(%{"type" => "response.completed"})

    assert WebSocketProtocol.terminal_message?(message)
  end

  test "identifies error messages" do
    message = Jason.encode!(%{"type" => "error", "error" => %{"message" => "boom"}})

    assert WebSocketProtocol.error_message?(message)
  end
end
