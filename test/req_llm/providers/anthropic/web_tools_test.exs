defmodule ReqLLM.Providers.Anthropic.WebToolsTest do
  @moduledoc """
  Tests Anthropic web fetch and web search tool configuration.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Providers.Anthropic

  describe "web fetch tool" do
    test "encode_body with web_fetch configuration" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_fetch: %{
              max_uses: 3,
              allowed_domains: ["example.com", "docs.example.com"]
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [web_fetch_tool] = decoded["tools"]
      assert web_fetch_tool["type"] == "web_fetch_20260209"
      assert web_fetch_tool["name"] == "web_fetch"
      assert web_fetch_tool["max_uses"] == 3
      assert web_fetch_tool["allowed_domains"] == ["example.com", "docs.example.com"]
    end

    test "encode_body with web_fetch citations and max_content_tokens" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_fetch: %{
              max_content_tokens: 50_000,
              citations: %{enabled: true}
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [web_fetch_tool] = decoded["tools"]
      assert web_fetch_tool["max_content_tokens"] == 50_000
      assert web_fetch_tool["citations"] == %{"enabled" => true}
    end

    test "encode_body with web_fetch defaults (empty config)" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_fetch: %{}
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [web_fetch_tool] = decoded["tools"]
      assert web_fetch_tool["type"] == "web_fetch_20260209"
      assert web_fetch_tool["name"] == "web_fetch"
      refute Map.has_key?(web_fetch_tool, "max_uses")
    end

    test "encode_body with both regular tools and web_fetch" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [location: [type: :string, required: true, doc: "City"]],
          callback: fn _ -> {:ok, "sunny"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          provider_options: [
            web_fetch: %{max_uses: 2}
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert length(decoded["tools"]) == 2
      [regular_tool, web_fetch_tool] = decoded["tools"]
      assert regular_tool["name"] == "get_weather"
      assert web_fetch_tool["type"] == "web_fetch_20260209"
      assert web_fetch_tool["name"] == "web_fetch"
      assert web_fetch_tool["max_uses"] == 2
    end

    test "encode_body with web_fetch and web_search combined" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{max_uses: 5},
            web_fetch: %{max_uses: 3}
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert length(decoded["tools"]) == 2
      tool_types = Enum.map(decoded["tools"], & &1["type"])
      assert "web_search_20250305" in tool_types
      assert "web_fetch_20260209" in tool_types
    end
  end

  describe "web search tool" do
    test "encode_body with web_search configuration" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              max_uses: 5,
              allowed_domains: ["wikipedia.org", "britannica.com"]
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["name"] == "web_search"
      assert web_search_tool["max_uses"] == 5
      assert web_search_tool["allowed_domains"] == ["wikipedia.org", "britannica.com"]
    end

    test "encode_body with web_search and user location" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      user_location = %{
        type: "approximate",
        city: "San Francisco",
        region: "California",
        country: "US",
        timezone: "America/Los_Angeles"
      }

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              max_uses: 3,
              user_location: user_location
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["max_uses"] == 3
      # After JSON encoding/decoding, keys become strings
      assert web_search_tool["user_location"]["type"] == "approximate"
      assert web_search_tool["user_location"]["city"] == "San Francisco"
      assert web_search_tool["user_location"]["region"] == "California"
      assert web_search_tool["user_location"]["country"] == "US"
      assert web_search_tool["user_location"]["timezone"] == "America/Los_Angeles"
    end

    test "encode_body with web_search and blocked_domains" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              blocked_domains: ["untrustedsource.com"]
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["blocked_domains"] == ["untrustedsource.com"]
      refute Map.has_key?(web_search_tool, "max_uses")
    end

    test "encode_body with both regular tools and web_search" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather for a location",
          parameter_schema: [
            location: [type: :string, required: true]
          ],
          callback: fn _ -> {:ok, "Sunny"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          provider_options: [
            web_search: %{max_uses: 5}
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 2

      [regular_tool, web_search_tool] = decoded["tools"]
      assert regular_tool["name"] == "get_weather"
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["name"] == "web_search"
      assert web_search_tool["max_uses"] == 5
    end
  end
end
