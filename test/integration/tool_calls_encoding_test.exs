defmodule ReqLLM.Integration.ToolCallsEncodingTest do
  @moduledoc """
  Integration test demonstrating that tool_calls encoding works correctly
  for OpenAI-style API requests. This verifies the fix for GitHub issue #44.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Context.Codec
  alias ReqLLM.Message
  alias ReqLLM.Model

  describe "OpenAI tool calling integration" do
    test "encodes a complete conversation with tool calls correctly" do
      # Simulate a conversation where:
      # 1. User asks a question requiring tool use
      # 2. Assistant makes tool calls
      # 3. Tool returns results
      # 4. Assistant provides final answer

      messages = [
        %Message{
          role: :user,
          content: [
            %Message.ContentPart{type: :text, text: "What's the weather in Paris and New York?"}
          ]
        },
        %Message{
          role: :assistant,
          content: [],
          tool_calls: [
            %{
              id: "call_abc123",
              type: "function",
              function: %{
                name: "get_weather",
                arguments: Jason.encode!(%{location: "Paris", unit: "celsius"})
              }
            },
            %{
              id: "call_def456",
              type: "function",
              function: %{
                name: "get_weather",
                arguments: Jason.encode!(%{location: "New York", unit: "celsius"})
              }
            }
          ]
        },
        %Message{
          role: :tool,
          content: [%Message.ContentPart{type: :text, text: "Paris: 22°C, sunny"}],
          tool_call_id: "call_abc123"
        },
        %Message{
          role: :tool,
          content: [%Message.ContentPart{type: :text, text: "New York: 18°C, cloudy"}],
          tool_call_id: "call_def456"
        },
        %Message{
          role: :assistant,
          content: [
            %Message.ContentPart{
              type: :text,
              text:
                "The weather in Paris is 22°C and sunny, while in New York it's 18°C and cloudy."
            }
          ]
        }
      ]

      context = Context.new(messages)
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      # Verify the structure matches OpenAI's expected format
      assert result.model == "gpt-4"
      assert length(result.messages) == 5

      # Check that the assistant message with tool_calls is properly encoded
      [_user, assistant_with_tools, _tool1, _tool2, _final_assistant] = result.messages

      assert assistant_with_tools.role == "assistant"
      assert assistant_with_tools.content == []
      assert Map.has_key?(assistant_with_tools, :tool_calls)
      assert length(assistant_with_tools.tool_calls) == 2

      [paris_call, ny_call] = assistant_with_tools.tool_calls
      assert paris_call.id == "call_abc123"
      assert paris_call.function.name == "get_weather"
      assert paris_call.function.arguments =~ "Paris"

      assert ny_call.id == "call_def456"
      assert ny_call.function.name == "get_weather"
      assert ny_call.function.arguments =~ "New York"
    end

    test "correctly formats for OpenAI parallel function calling" do
      # OpenAI supports parallel function calling where multiple tools
      # can be called in a single assistant message
      message = %Message{
        role: :assistant,
        content: [
          %Message.ContentPart{
            type: :text,
            text: "I'll get that information for you."
          }
        ],
        tool_calls: [
          %{
            id: "call_1",
            type: "function",
            function: %{
              name: "search_web",
              arguments: Jason.encode!(%{query: "latest AI news"})
            }
          },
          %{
            id: "call_2",
            type: "function",
            function: %{
              name: "get_stock_price",
              arguments: Jason.encode!(%{symbol: "NVDA"})
            }
          },
          %{
            id: "call_3",
            type: "function",
            function: %{
              name: "calculate",
              arguments: Jason.encode!(%{expression: "2^10"})
            }
          }
        ]
      }

      context = Context.new([message])
      model = %Model{provider: :openai, model: "gpt-4o"}

      result = Codec.encode_request(context, model)

      assert result.model == "gpt-4o"
      [encoded_message] = result.messages

      # Verify OpenAI format requirements
      assert encoded_message.role == "assistant"
      assert encoded_message.content == "I'll get that information for you."
      assert length(encoded_message.tool_calls) == 3

      # Verify each tool call maintains its structure
      tool_names = Enum.map(encoded_message.tool_calls, & &1.function.name)
      assert tool_names == ["search_web", "get_stock_price", "calculate"]
    end
  end
end
