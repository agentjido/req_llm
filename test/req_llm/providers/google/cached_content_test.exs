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
