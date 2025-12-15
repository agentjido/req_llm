defmodule ReqLLM.Providers.GoogleVertex.GeminiTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.GoogleVertex.Gemini

  defp context_fixture(user_message \\ "Hello, how are you?") do
    Context.new([
      Context.system("You are a helpful assistant."),
      Context.user(user_message)
    ])
  end

  describe "format_request/3 grounding tool transformation" do
    test "transforms google_search to googleSearch for Vertex AI" do
      context = context_fixture("What's the weather today?")

      opts = [
        google_grounding: %{enable: true},
        max_tokens: 1000
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Verify grounding tool uses camelCase for Vertex AI
      assert %{"tools" => tools} = body
      assert Enum.any?(tools, &match?(%{"googleSearch" => %{}}, &1))
      refute Enum.any?(tools, &match?(%{"google_search" => _}, &1))
    end

    test "transforms google_search_retrieval with dynamic_retrieval_config to camelCase" do
      context = context_fixture("Search something")

      opts = [
        google_grounding: %{dynamic_retrieval: %{mode: "MODE_DYNAMIC", dynamic_threshold: 0.7}},
        max_tokens: 1000
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Verify grounding tool uses camelCase for Vertex AI
      assert %{"tools" => tools} = body

      retrieval_tool = Enum.find(tools, &Map.has_key?(&1, "googleSearchRetrieval"))
      assert retrieval_tool != nil
      assert %{"googleSearchRetrieval" => %{"dynamicRetrievalConfig" => config}} = retrieval_tool
      assert config["mode"] == "MODE_DYNAMIC"

      # Ensure snake_case versions are NOT present
      refute Enum.any?(tools, &Map.has_key?(&1, "google_search_retrieval"))
    end

    test "preserves functionDeclarations when grounding is used with tools" do
      context = context_fixture("Get weather")

      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "get_weather",
          description: "Get weather for a location",
          parameter_schema: [
            location: [type: :string, required: true, doc: "The city"]
          ],
          callback: fn _args -> {:ok, "sunny"} end
        )

      opts = [
        google_grounding: %{enable: true},
        tools: [tool],
        max_tokens: 1000
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      assert %{"tools" => tools} = body

      # Should have both grounding and function tools
      assert Enum.any?(tools, &match?(%{"googleSearch" => %{}}, &1))
      assert Enum.any?(tools, &Map.has_key?(&1, "functionDeclarations"))
    end

    test "format_request without grounding produces no grounding tools" do
      context = context_fixture()

      opts = [max_tokens: 1000]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Should not have tools key if no grounding and no function tools
      refute Map.has_key?(body, "tools")
    end
  end
end
