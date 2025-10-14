defmodule ReqLLM.Providers.AmazonBedrock.ConverseTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.AmazonBedrock.Converse

  describe "format_request/3" do
    test "formats basic request with messages" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hello"}
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["messages"] == [
               %{"role" => "user", "content" => [%{"text" => "Hello"}]}
             ]
    end

    test "formats request with system message" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :system, content: "You are helpful"},
          %Message{role: :user, content: "Hello"}
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["system"] == [%{"text" => "You are helpful"}]
      assert result["messages"] == [%{"role" => "user", "content" => [%{"text" => "Hello"}]}]
    end

    test "formats request with tools" do
      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [
            location: [type: :string, required: true]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Test"}]}

      result = Converse.format_request("test-model", context, tools: [tool])

      assert result["toolConfig"]["tools"] == [
               %{
                 "toolSpec" => %{
                   "name" => "get_weather",
                   "description" => "Get weather",
                   "inputSchema" => %{
                     "json" => %{
                       "type" => "object",
                       "properties" => %{
                         "location" => %{"type" => "string"}
                       },
                       "required" => ["location"],
                       "additionalProperties" => false
                     }
                   }
                 }
               }
             ]
    end

    test "formats request with inference config" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Test"}]}

      result =
        Converse.format_request("test-model", context,
          max_tokens: 1000,
          temperature: 0.7,
          top_p: 0.9
        )

      assert result["inferenceConfig"] == %{
               "maxTokens" => 1000,
               "temperature" => 0.7,
               "topP" => 0.9
             }
    end

    test "formats request with content blocks" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :user,
            content: [
              ContentPart.text("Hello"),
              ContentPart.text("World")
            ]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["messages"] == [
               %{
                 "role" => "user",
                 "content" => [%{"text" => "Hello"}, %{"text" => "World"}]
               }
             ]
    end

    test "formats request with tool_call content" do
      tool_call = ReqLLM.ToolCall.new("call_123", "get_weather", Jason.encode!(%{location: "SF"}))

      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [tool_call]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "toolUse" => %{
                       "toolUseId" => "call_123",
                       "name" => "get_weather",
                       "input" => %{"location" => "SF"}
                     }
                   }
                 ]
               }
             ]
    end

    test "formats request with tool_result content" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :tool,
            tool_call_id: "call_123",
            content: [ContentPart.text("Weather is sunny")]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["messages"] == [
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "toolResult" => %{
                       "toolUseId" => "call_123",
                       "content" => [%{"text" => "Weather is sunny"}]
                     }
                   }
                 ]
               }
             ]
    end
  end

  describe "parse_response/2" do
    test "parses basic text response" do
      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"text" => "Hello!"}]
          }
        },
        "stopReason" => "end_turn",
        "usage" => %{
          "inputTokens" => 10,
          "outputTokens" => 5
        }
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test-model")

      assert result.model == "test-model"
      assert result.finish_reason == :stop
      assert result.usage == %{input_tokens: 10, output_tokens: 5}
      assert result.message.role == :assistant
      assert [%ContentPart{type: :text, text: "Hello!"}] = result.message.content
    end

    test "parses tool_use response" do
      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"text" => "Let me check"},
              %{
                "toolUse" => %{
                  "toolUseId" => "call_123",
                  "name" => "get_weather",
                  "input" => %{"location" => "SF"}
                }
              }
            ]
          }
        },
        "stopReason" => "tool_use",
        "usage" => %{
          "inputTokens" => 100,
          "outputTokens" => 50
        }
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test-model")

      assert result.finish_reason == :tool_calls
      assert result.message.role == :assistant

      # Text should be in content
      [text_part] = result.message.content
      assert text_part.type == :text
      assert text_part.text == "Let me check"

      # Tool calls should be in tool_calls field
      assert length(result.message.tool_calls) == 1
      [tool_call] = result.message.tool_calls
      assert tool_call.id == "call_123"
      assert tool_call.function.name == "get_weather"
      arguments = Jason.decode!(tool_call.function.arguments)
      assert arguments == %{"location" => "SF"}
    end

    test "maps stop reasons correctly" do
      test_cases = [
        {"end_turn", :stop},
        {"tool_use", :tool_calls},
        {"max_tokens", :length},
        {"stop_sequence", :stop},
        {"content_filtered", :content_filter}
      ]

      for {bedrock_reason, expected_reason} <- test_cases do
        response_body = %{
          "output" => %{"message" => %{"role" => "assistant", "content" => []}},
          "stopReason" => bedrock_reason
        }

        {:ok, result} = Converse.parse_response(response_body, model: "test")
        assert result.finish_reason == expected_reason
      end
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses contentBlockDelta with text" do
      chunk = %{
        "contentBlockDelta" => %{
          "delta" => %{"text" => "Hello"}
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")
      assert result == %{type: :text, text: "Hello"}
    end

    test "parses messageStop with finish reason" do
      chunk = %{
        "messageStop" => %{
          "stopReason" => "end_turn"
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")
      assert result == %{type: :done, finish_reason: :stop}
    end

    test "parses metadata with usage" do
      chunk = %{
        "metadata" => %{
          "usage" => %{
            "inputTokens" => 100,
            "outputTokens" => 50
          }
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")
      assert result == %{type: :usage, usage: %{input_tokens: 100, output_tokens: 50}}
    end

    test "returns nil for messageStart" do
      {:ok, result} = Converse.parse_stream_chunk(%{"messageStart" => %{}}, "test-model")
      assert is_nil(result)
    end

    test "returns nil for contentBlockStart" do
      {:ok, result} = Converse.parse_stream_chunk(%{"contentBlockStart" => %{}}, "test-model")
      assert is_nil(result)
    end

    test "returns nil for contentBlockStop" do
      {:ok, result} = Converse.parse_stream_chunk(%{"contentBlockStop" => %{}}, "test-model")
      assert is_nil(result)
    end
  end
end
