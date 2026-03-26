defmodule Provider.OpenAI.WebSocketTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.WebSocket

  describe "headers/2" do
    test "includes auth and custom headers" do
      headers =
        WebSocket.headers(
          model(),
          api_key: "socket-test-key",
          req_http_options: [headers: [{"X-Test", "1"}]]
        )

      assert headers == [
               {"Authorization", "Bearer socket-test-key"},
               {"X-Test", "1"}
             ]
    end
  end

  describe "responses_url/2" do
    test "prefers model base_url over request options" do
      url =
        WebSocket.responses_url(
          model(base_url: "http://localhost:4010/custom/"),
          base_url: "https://ignored.example.com/v1"
        )

      assert url == "ws://localhost:4010/custom/responses"
    end
  end

  describe "realtime_url/2" do
    test "uses provider_model_id and preserves existing query params" do
      url =
        WebSocket.realtime_url(
          model(
            base_url: "https://api.example.com/v1?api-version=2025-01-01",
            provider_model_id: "gpt-5-deploy"
          ),
          []
        )

      uri = URI.parse(url)

      assert uri.scheme == "wss"
      assert uri.path == "/v1/realtime"

      assert URI.decode_query(uri.query) == %{
               "api-version" => "2025-01-01",
               "model" => "gpt-5-deploy"
             }
    end
  end

  describe "websocket_url/3" do
    test "normalizes common schemes and joins paths" do
      assert WebSocket.websocket_url("http://example.com/base/", "/responses") ==
               "ws://example.com/base/responses"

      assert WebSocket.websocket_url("https://example.com/v1", "/responses") ==
               "wss://example.com/v1/responses"

      assert WebSocket.websocket_url("ws://example.com/v1", "/responses") ==
               "ws://example.com/v1/responses"

      assert WebSocket.websocket_url("wss://example.com/v1", "/responses") ==
               "wss://example.com/v1/responses"
    end

    test "returns a root path when the suffix is empty" do
      assert WebSocket.websocket_url("https://example.com", "") == "wss://example.com/"
    end

    test "preserves passthrough schemes and merges query values" do
      url =
        WebSocket.websocket_url("custom://example.com/v1?bad=%ZZ", "/responses", model: "gpt-5")

      uri = URI.parse(url)

      assert uri.scheme == "custom"
      assert uri.path == "/v1/responses"
      assert URI.decode_query(uri.query) == %{"bad" => "%ZZ", "model" => "gpt-5"}
    end
  end

  defp model(attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    LLMDB.Model.new!(
      Map.merge(
        %{
          provider: :openai,
          id: "gpt-5"
        },
        attrs
      )
    )
  end
end
