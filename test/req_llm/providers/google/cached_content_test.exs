defmodule ReqLLM.Providers.Google.CachedContentTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Google.CachedContent

  describe "create/1" do
    @tag :skip
    test "creates cached content for Google AI Studio" do
      # Skip in CI - requires API key
      opts = [
        provider: :google,
        model: "gemini-2.5-flash",
        api_key: System.get_env("GOOGLE_API_KEY"),
        contents: [
          %{
            role: "user",
            parts: [
              %{
                text:
                  String.duplicate(
                    "This is test content that needs to be long enough to meet the minimum token requirement. ",
                    100
                  )
              }
            ]
          }
        ],
        system_instruction: "You are a helpful assistant",
        ttl: "600s",
        display_name: "Test Cache"
      ]

      assert {:ok, cache} = CachedContent.create(opts)
      assert cache.name
      assert cache.create_time
      assert cache.expire_time
    end

    @tag :skip
    test "creates cached content for Vertex AI" do
      # Skip in CI - requires service account
      opts = [
        provider: :google_vertex,
        model: "gemini-2.5-flash",
        service_account_json: System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
        project_id: System.get_env("GOOGLE_CLOUD_PROJECT"),
        region: "us-central1",
        contents: [
          %{
            role: "user",
            parts: [
              %{
                text:
                  String.duplicate(
                    "This is test content that needs to be long enough to meet the minimum token requirement. ",
                    100
                  )
              }
            ]
          }
        ],
        system_instruction: "You are a helpful assistant",
        ttl: "600s"
      ]

      assert {:ok, cache} = CachedContent.create(opts)
      assert cache.name
      assert String.contains?(cache.name, "cachedContents")
      assert cache.create_time
      assert cache.expire_time
    end

    test "returns error for unsupported provider" do
      opts = [
        provider: :openai,
        model: "gpt-4",
        api_key: "test"
      ]

      assert {:error, message} = CachedContent.create(opts)
      assert message =~ "Unsupported provider"
    end

    test "returns error for Anthropic on Vertex" do
      opts = [
        provider: :google_vertex_anthropic,
        model: "claude-haiku-4-5",
        service_account_json: "test.json",
        project_id: "test"
      ]

      assert {:error, message} = CachedContent.create(opts)
      assert message =~ "only supported for Gemini models"
    end
  end

  describe "base_url and req_http_options" do
    test "create/1 defaults to the Google AI Studio base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "generativelanguage.googleapis.com"
        assert conn.request_path == "/v1beta/cachedContents"

        Req.Test.json(conn, %{"name" => "cachedContents/test-cache"})
      end)

      assert {:ok, cache} =
               CachedContent.create(
                 provider: :google,
                 model: "gemini-2.5-flash",
                 api_key: "test-key",
                 contents: [%{role: "user", parts: [%{text: "Content to cache"}]}],
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert cache.name == "cachedContents/test-cache"
    end

    test "create/1 sends the request to a custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "localhost"
        assert conn.port == 9999
        assert conn.request_path == "/custom/v1beta/cachedContents"
        assert %{"key" => "test-key"} = URI.decode_query(conn.query_string)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["model"] == "models/gemini-2.5-flash"
        assert [%{"role" => "user"}] = payload["contents"]

        Req.Test.json(conn, %{
          "name" => "cachedContents/test-cache",
          "createTime" => "2025-01-01T00:00:00Z",
          "expireTime" => "2025-01-01T01:00:00Z"
        })
      end)

      assert {:ok, cache} =
               CachedContent.create(
                 provider: :google,
                 model: "gemini-2.5-flash",
                 api_key: "test-key",
                 contents: [%{role: "user", parts: [%{text: "Content to cache"}]}],
                 base_url: "http://localhost:9999/custom/v1beta/",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert cache.name == "cachedContents/test-cache"
      assert cache.create_time == "2025-01-01T00:00:00Z"
      assert cache.expire_time == "2025-01-01T01:00:00Z"
    end

    test "get/1 sends the request to a custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.host == "localhost"
        assert conn.request_path == "/custom/v1beta/cachedContents/abc123"
        assert %{"key" => "test-key"} = URI.decode_query(conn.query_string)

        Req.Test.json(conn, %{"name" => "cachedContents/abc123"})
      end)

      assert {:ok, cache} =
               CachedContent.get(
                 provider: :google,
                 name: "cachedContents/abc123",
                 api_key: "test-key",
                 base_url: "http://localhost/custom/v1beta",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert cache.name == "cachedContents/abc123"
    end

    test "list/1 sends the request to a custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.host == "localhost"
        assert conn.request_path == "/custom/v1beta/cachedContents"

        assert %{"key" => "test-key", "pageSize" => "5"} =
                 URI.decode_query(conn.query_string)

        Req.Test.json(conn, %{"cachedContents" => [%{"name" => "cachedContents/abc123"}]})
      end)

      assert {:ok, %{"cachedContents" => [cache]}} =
               CachedContent.list(
                 provider: :google,
                 api_key: "test-key",
                 page_size: 5,
                 base_url: "http://localhost/custom/v1beta",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert cache["name"] == "cachedContents/abc123"
    end

    test "update/1 sends the request to a custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "PATCH"
        assert conn.host == "localhost"
        assert conn.request_path == "/custom/v1beta/cachedContents/abc123"

        assert %{"key" => "test-key", "updateMask" => "ttl"} =
                 URI.decode_query(conn.query_string)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"ttl" => "7200s"} = Jason.decode!(body)

        Req.Test.json(conn, %{"name" => "cachedContents/abc123"})
      end)

      assert {:ok, cache} =
               CachedContent.update(
                 provider: :google,
                 name: "cachedContents/abc123",
                 ttl: "7200s",
                 api_key: "test-key",
                 base_url: "http://localhost/custom/v1beta",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert cache.name == "cachedContents/abc123"
    end

    test "delete/1 sends the request to a custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.host == "localhost"
        assert conn.request_path == "/custom/v1beta/cachedContents/abc123"
        assert %{"key" => "test-key"} = URI.decode_query(conn.query_string)

        Req.Test.json(conn, %{})
      end)

      assert :ok =
               CachedContent.delete(
                 provider: :google,
                 name: "cachedContents/abc123",
                 api_key: "test-key",
                 base_url: "http://localhost/custom/v1beta",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  describe "cached_content parameter in requests" do
    test "Google provider schema accepts cached_content option" do
      # Verify the provider schema accepts cached_content
      assert :cached_content in ReqLLM.Providers.Google.supported_provider_options()
    end

    @tag :skip
    test "Vertex provider schema accepts cached_content option" do
      # NOTE: This will be enabled when Vertex Gemini support is added
      # Vertex caching requires Gemini models (not Claude models)
      assert :cached_content in ReqLLM.Providers.GoogleVertex.supported_provider_options()
    end
  end
end
