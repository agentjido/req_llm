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

  describe "format_request/3 grounding" do
    test "includes google_search tool when grounding enabled" do
      context = context_fixture("What's the weather today?")

      opts = [
        google_grounding: %{enable: true},
        max_tokens: 1000
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Verify grounding tool uses snake_case (same as Google AI REST API)
      assert %{"tools" => tools} = body
      assert Enum.any?(tools, &match?(%{"google_search" => %{}}, &1))
    end

    test "includes google_search_retrieval with dynamic_retrieval_config" do
      context = context_fixture("Search something")

      opts = [
        google_grounding: %{dynamic_retrieval: %{mode: "MODE_DYNAMIC", dynamic_threshold: 0.7}},
        max_tokens: 1000
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Verify grounding tool uses snake_case
      assert %{"tools" => tools} = body

      retrieval_tool = Enum.find(tools, &Map.has_key?(&1, "google_search_retrieval"))
      assert retrieval_tool != nil

      assert %{"google_search_retrieval" => %{"dynamic_retrieval_config" => config}} =
               retrieval_tool

      assert config["mode"] == "MODE_DYNAMIC"
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
      assert Enum.any?(tools, &match?(%{"google_search" => %{}}, &1))
      assert Enum.any?(tools, &Map.has_key?(&1, "functionDeclarations"))
    end

    test "format_request without grounding produces no grounding tools" do
      context = context_fixture()

      opts = [max_tokens: 1000]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      # Should not have tools key if no grounding and no function tools
      refute Map.has_key?(body, "tools")
    end

    test "works with google_grounding at top level (as Options.process provides)" do
      # After Options.process, google_grounding is hoisted to top level
      # This test verifies format_request works with that structure
      context = context_fixture("What's the news?")

      # Simulates opts AFTER Options.process (which hoists provider_options to top level)
      opts = [
        max_tokens: 1000,
        google_grounding: %{enable: true},
        provider_options: [google_grounding: %{enable: true}]
      ]

      body = Gemini.format_request("gemini-2.5-flash", context, opts)

      assert %{"tools" => tools} = body
      assert Enum.any?(tools, &match?(%{"google_search" => %{}}, &1))
    end
  end
end
