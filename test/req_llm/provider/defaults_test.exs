defmodule ReqLLM.Provider.DefaultsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.{Context, Message, Message.ContentPart, Model, StreamChunk}

  describe "encode_context_to_openai_format/2" do
    test "encodes text content correctly" do
      test_cases = [
        # Simple string content
        {%Message{role: :user, content: "Hello"}, "Hello"},
        # Single text part flattens to string
        {%Message{role: :user, content: [%ContentPart{type: :text, text: "Hello"}]}, "Hello"},
        # Multiple text parts stay as array
        {%Message{
           role: :user,
           content: [
             %ContentPart{type: :text, text: "Hello"},
             %ContentPart{type: :text, text: "World"}
           ]
         }, [%{type: "text", text: "Hello"}, %{type: "text", text: "World"}]}
      ]

      for {message, expected_content} <- test_cases do
        context = %Context{messages: [message]}
        result = Defaults.encode_context_to_openai_format(context, "gpt-4")

        assert result == %{messages: [%{role: "user", content: expected_content}]}
      end
    end

    test "encodes tool calls correctly" do
      # Test message-level tool_calls
      message_tool_calls = %Message{
        role: :assistant,
        content: [],
        tool_calls: [
          %{
            id: "call_123",
            type: "function",
            function: %{name: "get_weather", arguments: ~s({"city":"New York"})}
          }
        ]
      }

      # Test content-part level tool calls
      content_tool_calls = %Message{
        role: :assistant,
        content: [
          %ContentPart{
            type: :tool_call,
            tool_name: "get_weather",
            input: %{city: "New York"},
            tool_call_id: "call_123"
          }
        ]
      }

      # Both should result in the same encoding: tool_calls at the top level

      result1 =
        Defaults.encode_context_to_openai_format(
          %Context{messages: [message_tool_calls]},
          "gpt-4"
        )

      result2 =
        Defaults.encode_context_to_openai_format(
          %Context{messages: [content_tool_calls]},
          "gpt-4"
        )

      # Both should have the same structure
      assert %{messages: [%{role: "assistant", tool_calls: [tool_call1]}]} = result1
      assert %{messages: [%{role: "assistant", tool_calls: [tool_call2]}]} = result2

      # Verify tool call structure 
      assert tool_call1["id"] == "call_123"
      assert tool_call1["type"] == "function"
      assert tool_call1["function"]["name"] == "get_weather"
      assert tool_call1["function"]["arguments"] == ~s({"city":"New York"})

      assert tool_call2["id"] == "call_123"
      assert tool_call2["type"] == "function"
      assert tool_call2["function"]["name"] == "get_weather"
      assert Jason.decode!(tool_call2["function"]["arguments"]) == %{"city" => "New York"}
    end

    test "encodes tool messages correctly" do
      # Test tool message with result
      tool_result_message = %Message{
        role: :tool,
        content: [
          %ContentPart{
            type: :tool_result,
            tool_call_id: "call_123",
            output: %{temperature: "72F", condition: "sunny"}
          }
        ]
      }

      expected_result = %{
        messages: [
          %{
            role: "tool",
            tool_call_id: "call_123",
            content: ~s({"temperature":"72F","condition":"sunny"})
          }
        ]
      }

      assert Defaults.encode_context_to_openai_format(
               %Context{messages: [tool_result_message]},
               "gpt-4"
             ) == expected_result
    end

    test "normalizes tool call arguments to JSON strings" do
      # Test with map arguments (should be JSON encoded)
      map_args_message = %Message{
        role: :assistant,
        content: [],
        tool_calls: [
          %{
            id: "call_456",
            function: %{name: "calculate", arguments: %{a: 1, b: 2}}
          }
        ]
      }

      result =
        Defaults.encode_context_to_openai_format(
          %Context{messages: [map_args_message]},
          "gpt-4"
        )

      # Extract the tool call to verify the structure and content
      assert %{messages: [%{role: "assistant", tool_calls: [tool_call]}]} = result
      assert tool_call["id"] == "call_456"
      assert tool_call["type"] == "function"
      assert tool_call["function"]["name"] == "calculate"
      # Verify arguments is valid JSON that parses to the original map
      assert Jason.decode!(tool_call["function"]["arguments"]) == %{"a" => 1, "b" => 2}
    end

    test "combines text content and tool calls correctly" do
      # Assistant message with both text and tool call
      mixed_message = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :text, text: "I'll check the weather for you."},
          %ContentPart{
            type: :tool_call,
            tool_name: "get_weather",
            input: %{city: "New York"},
            tool_call_id: "call_789"
          }
        ]
      }

      expected_result = %{
        messages: [
          %{
            role: "assistant",
            content: "I'll check the weather for you.",
            tool_calls: [
              %{
                "id" => "call_789",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"New York"})}
              }
            ]
          }
        ]
      }

      assert Defaults.encode_context_to_openai_format(
               %Context{messages: [mixed_message]},
               "gpt-4"
             ) == expected_result
    end
  end

  describe "decode_response_body_openai_format/2" do
    setup do
      %{model: %Model{provider: :openai, model: "gpt-4"}}
    end

    test "decodes responses correctly", %{model: model} do
      test_cases = [
        # Basic text response
        {%{
           "id" => "chatcmpl-123",
           "model" => "gpt-4",
           "choices" => [
             %{"message" => %{"content" => "Hello there!"}, "finish_reason" => "stop"}
           ],
           "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
         },
         fn result ->
           assert result.id == "chatcmpl-123"
           assert result.finish_reason == :stop
           assert result.usage == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
           assert result.message.content == [%ContentPart{type: :text, text: "Hello there!"}]
         end},

        # Tool call response
        {%{
           "id" => "chatcmpl-456",
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_123",
                     "type" => "function",
                     "function" => %{
                       "name" => "get_weather",
                       "arguments" => ~s({"city":"New York"})
                     }
                   }
                 ]
               },
               "finish_reason" => "tool_calls"
             }
           ]
         },
         fn result ->
           assert result.finish_reason == :tool_calls
           assert [tool_call_part] = result.message.content
           assert tool_call_part.type == :tool_call
           assert tool_call_part.tool_name == "get_weather"
           assert tool_call_part.input == %{"city" => "New York"}
           assert tool_call_part.tool_call_id == "call_123"
         end},

        # Missing fields handled gracefully  
        {%{"choices" => [%{"message" => %{"content" => "Hello"}}]},
         fn result ->
           assert result.id == "unknown"
           assert result.model == "gpt-4"
           assert result.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
           assert result.finish_reason == nil
         end}
      ]

      for {response_data, assertion_fn} <- test_cases do
        {:ok, result} = Defaults.decode_response_body_openai_format(response_data, model)
        assertion_fn.(result)
      end
    end
  end

  describe "default_decode_sse_event/2" do
    setup do
      %{model: %Model{provider: :openai, model: "gpt-4"}}
    end

    test "decodes streaming events correctly", %{model: model} do
      # Content delta
      content_event = %{data: %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}}

      assert Defaults.default_decode_sse_event(content_event, model) == [
               %StreamChunk{type: :content, text: "Hello"}
             ]

      # Tool call delta with valid JSON
      tool_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"city":"New York"})
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Defaults.default_decode_sse_event(tool_event, model)
      assert chunk.type == :tool_call
      assert chunk.name == "get_weather"
      assert chunk.arguments == %{"city" => "New York"}
      assert chunk.metadata == %{id: "call_123"}
    end

    test "handles edge cases gracefully", %{model: model} do
      # Empty/invalid events
      assert Defaults.default_decode_sse_event(%{data: %{}}, model) == []
      assert Defaults.default_decode_sse_event(%{}, model) == []
      assert Defaults.default_decode_sse_event("invalid", model) == []

      # Tool call with invalid JSON - should fallback to empty map
      invalid_json_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{"name" => "get_weather", "arguments" => "invalid json"}
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Defaults.default_decode_sse_event(invalid_json_event, model)
      assert chunk.type == :tool_call
      assert chunk.arguments == %{}
    end
  end
end
