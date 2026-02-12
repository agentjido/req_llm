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

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Providers.Google.ResponseBuilder

    test "extracts reasoning_details from thinking chunks for Vertex Gemini models" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        signature: "thought-sig-abc",
        encrypted?: false,
        provider: :google,
        format: "google-gemini-v1",
        provider_data: %{"type" => "thought"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Analyzing the problem carefully", thinking_meta),
        ReqLLM.StreamChunk.thinking("Considering edge cases", thinking_meta),
        ReqLLM.StreamChunk.text("Here is my answer.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = first
      assert first.text == "Analyzing the problem carefully"
      assert first.provider == :google
      assert first.format == "google-gemini-v1"
      assert first.index == 0

      assert second.text == "Considering edge cases"
      assert second.index == 1
    end

    test "preserves signature from thinking chunk metadata" do
      model = %LLMDB.Model{
        id: "gemini-2.5-pro",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        signature: "thought-signature-xyz",
        encrypted?: false,
        provider: :google,
        format: "google-gemini-v1",
        provider_data: %{"type" => "thought"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Deep thinking content", thinking_meta),
        ReqLLM.StreamChunk.text("Final response.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      [first] = response.message.reasoning_details
      assert first.signature == "thought-signature-xyz"
    end

    test "returns nil reasoning_details when no thinking chunks" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Just a simple response.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details == nil
    end
  end

  describe "Sync flow - reasoning_details extraction (Gemini)" do
    test "extracts reasoning_details from Gemini response on Vertex (sync flow)" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        model: "gemini-2.5-flash",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      gemini_response_body = %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{
                  "text" => "Analyzing the problem",
                  "thought" => true,
                  "thoughtSignature" => "sig-xyz"
                },
                %{"text" => "Considering edge cases", "thought" => true},
                %{"text" => "Here is the final answer."}
              ]
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 50,
          "totalTokenCount" => 60
        }
      }

      {:ok, response} = Gemini.parse_response(gemini_response_body, model, [])

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert first.text == "Analyzing the problem"
      assert first.provider == :google
      assert first.format == "google-gemini-v1"
      assert first.signature == "sig-xyz"
      assert first.index == 0

      assert second.text == "Considering edge cases"
      assert second.index == 1
    end

    test "returns nil reasoning_details when no thought parts (sync flow)" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        model: "gemini-2.5-flash",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      gemini_response_body = %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"text" => "Just a simple response."}
              ]
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 5,
          "candidatesTokenCount" => 10,
          "totalTokenCount" => 15
        }
      }

      {:ok, response} = Gemini.parse_response(gemini_response_body, model, [])

      assert response.message.reasoning_details == nil
    end
  end

  describe "Sync flow - reasoning_details extraction (Claude on Vertex)" do
    alias ReqLLM.Providers.GoogleVertex.Anthropic, as: VertexAnthropic

    test "extracts reasoning_details from Claude response on Vertex (sync flow)" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      anthropic_response_body = %{
        "id" => "msg_vertex_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me reason through this"},
          %{"type" => "thinking", "thinking" => "Step by step analysis"},
          %{"type" => "text", "text" => "Here is my conclusion."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 60
        }
      }

      {:ok, response} = VertexAnthropic.parse_response(anthropic_response_body, model, [])

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert first.text == "Let me reason through this"
      assert first.provider == :anthropic
      assert first.format == "anthropic-thinking-v1"
      assert first.index == 0

      assert second.text == "Step by step analysis"
      assert second.index == 1
    end

    test "returns nil reasoning_details when no thinking content on Vertex Claude (sync flow)" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      anthropic_response_body = %{
        "id" => "msg_vertex_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [
          %{"type" => "text", "text" => "Simple response without thinking."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {:ok, response} = VertexAnthropic.parse_response(anthropic_response_body, model, [])

      assert response.message.reasoning_details == nil
    end
  end

  describe "option translation for Gemini thinking" do
    alias ReqLLM.Providers.GoogleVertex

    test "google_thinking_budget is in the Vertex provider schema" do
      schema_keys = GoogleVertex.provider_schema().schema |> Keyword.keys()
      assert :google_thinking_budget in schema_keys
    end

    test "translate_options maps reasoning_token_budget to google_thinking_budget for Gemini" do
      model = %LLMDB.Model{
        id: "gemini-2.5-pro",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      opts = [reasoning_token_budget: 16_384]
      {translated, _warnings} = GoogleVertex.translate_options(:chat, model, opts)

      assert Keyword.get(translated, :google_thinking_budget) == 16_384
    end

    test "translate_options maps reasoning_effort levels to google_thinking_budget for Gemini" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      test_cases = [
        {:none, 0},
        {:minimal, 2_048},
        {:low, 4_096},
        {:medium, 8_192},
        {:high, 16_384},
        {:xhigh, 32_768}
      ]

      for {effort, expected_budget} <- test_cases do
        opts = [reasoning_effort: effort]
        {translated, _warnings} = GoogleVertex.translate_options(:chat, model, opts)

        assert Keyword.get(translated, :google_thinking_budget) == expected_budget,
               "Expected reasoning_effort #{inspect(effort)} to map to budget #{expected_budget}"
      end
    end

    test "translate_options still delegates to Anthropic for Claude models" do
      model = %LLMDB.Model{
        id: "claude-sonnet-4-5-20250514",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      opts = [temperature: 0.7]
      {translated, _warnings} = GoogleVertex.translate_options(:chat, model, opts)

      # Should pass through without error (Anthropic translation)
      assert Keyword.get(translated, :temperature) == 0.7
    end

    test "pre_validate_options handles reasoning_effort in provider_options for Gemini" do
      model = %LLMDB.Model{
        id: "gemini-2.5-pro",
        provider: :google_vertex,
        capabilities: %{chat: true}
      }

      opts = [provider_options: [reasoning_effort: :high]]
      {validated, _warnings} = GoogleVertex.pre_validate_options(:chat, model, opts)

      provider_opts = Keyword.get(validated, :provider_options, [])
      assert Keyword.get(provider_opts, :google_thinking_budget) == 16_384
    end
  end

  describe "extract_usage/2" do
    test "maps cachedContentTokenCount to cached_tokens" do
      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 120,
          "cachedContentTokenCount" => 50
        }
      }

      model = %LLMDB.Model{id: "gemini-2.5-flash", provider: :google_vertex}

      assert {:ok, usage} = ReqLLM.Providers.GoogleVertex.Gemini.extract_usage(body, model)
      assert usage[:cached_tokens] == 50
    end
  end
end
