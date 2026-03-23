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

    test "drops assistant message with only empty text and no tool calls" do
      # Production scenario: after a tool call round-trip, the agent produces an
      # empty response. Context.text/3 wraps "" as [ContentPart.text("")].
      # The encoder must filter the empty ContentPart AND drop the now-empty message.
      tool_call = ReqLLM.ToolCall.new("call_123", "add", Jason.encode!(%{a: 2, b: 3}))

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: [ContentPart.text("What is 2+3?")]},
          %Message{role: :assistant, content: [ContentPart.text("")], tool_calls: [tool_call]},
          %Message{role: :tool, tool_call_id: "call_123", content: [ContentPart.text("5")]},
          %Message{role: :assistant, content: [ContentPart.text("")]},
          %Message{role: :user, content: [ContentPart.text("Thanks")]}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      roles = Enum.map(result["messages"], & &1["role"])

      # The empty assistant message should be dropped
      assert roles == ["user", "assistant", "user", "user"]
    end

    test "filters empty text ContentParts from assistant message with tool calls" do
      tool_call = ReqLLM.ToolCall.new("call_123", "add", Jason.encode!(%{a: 2, b: 3}))

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: [ContentPart.text("What is 2+3?")]},
          %Message{
            role: :assistant,
            content: [ContentPart.text("")],
            tool_calls: [tool_call]
          },
          %Message{role: :tool, tool_call_id: "call_123", content: [ContentPart.text("5")]},
          %Message{role: :user, content: [ContentPart.text("Thanks")]}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_user, assistant_msg | _rest] = result["messages"]

      # The empty text block should be filtered out, leaving only the toolUse block
      assert [%{"toolUse" => _}] = assistant_msg["content"]
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

    test "rejects contexts ending with unresolved tool calls" do
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

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Converse.format_request("test-model", context, [])
      end
    end

    test "formats request with sanitized tool call IDs when tool results are present" do
      tool_call =
        ReqLLM.ToolCall.new("functions.add:0", "get_weather", Jason.encode!(%{location: "SF"}))

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Call the tool"},
          %Message{role: :assistant, content: [], tool_calls: [tool_call]},
          %Message{role: :tool, tool_call_id: "functions.add:0", content: "Sunny"}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant_msg, tool_result_msg] = result["messages"]

      assert %{
               "content" => [
                 %{
                   "toolUse" => %{
                     "toolUseId" => assistant_id
                   }
                 }
               ]
             } = assistant_msg

      assert %{
               "content" => [
                 %{
                   "toolResult" => %{
                     "toolUseId" => tool_result_id
                   }
                 }
               ]
             } = tool_result_msg

      assert assistant_id == "functions_add_0"
      assert tool_result_id == assistant_id
    end

    test "formats request with tool call IDs capped to Converse max length" do
      long_id = String.duplicate("a", 80) <> ":0"
      tool_call = ReqLLM.ToolCall.new(long_id, "get_weather", Jason.encode!(%{location: "SF"}))

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Call the tool"},
          %Message{role: :assistant, content: [], tool_calls: [tool_call]},
          %Message{role: :tool, tool_call_id: long_id, content: "Sunny"}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant_msg, tool_result_msg] = result["messages"]

      assistant_id = get_in(assistant_msg, ["content", Access.at(0), "toolUse", "toolUseId"])

      tool_result_id =
        get_in(tool_result_msg, ["content", Access.at(0), "toolResult", "toolUseId"])

      assert assistant_id == tool_result_id
      assert String.length(assistant_id) == 64
      refute String.contains?(assistant_id, ":")
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

    test "formats tool_result with image content part" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :tool,
            tool_call_id: "call_img",
            content: [
              ContentPart.text("Image loaded: 768x1024"),
              ContentPart.image(<<0xFF, 0xD8, 0xFF>>, "image/jpeg")
            ]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      tool_result_content =
        get_in(result, [
          "messages",
          Access.at(0),
          "content",
          Access.at(0),
          "toolResult",
          "content"
        ])

      assert length(tool_result_content) == 2

      assert Enum.at(tool_result_content, 0) == %{"text" => "Image loaded: 768x1024"}

      image_block = Enum.at(tool_result_content, 1)
      assert image_block["image"]["format"] == "jpeg"
      assert image_block["image"]["source"]["bytes"] == Base.encode64(<<0xFF, 0xD8, 0xFF>>)
    end

    test "formats tool_result with image-only content" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :tool,
            tool_call_id: "call_img2",
            content: [
              ContentPart.image(<<0xFF, 0xD8>>, "image/jpeg")
            ]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      tool_result_content =
        get_in(result, [
          "messages",
          Access.at(0),
          "content",
          Access.at(0),
          "toolResult",
          "content"
        ])

      assert length(tool_result_content) == 1
      assert Enum.at(tool_result_content, 0)["image"]["format"] == "jpeg"
    end

    test "merges consecutive tool results into single user message" do
      tool_call_1 = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location":"Paris"}))
      tool_call_2 = ReqLLM.ToolCall.new("call_2", "get_weather", ~s({"location":"London"}))

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "What's the weather in Paris and London?"},
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [tool_call_1, tool_call_2]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: [ContentPart.text("22°C and sunny")]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_2",
            content: [ContentPart.text("18°C and cloudy")]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])

      messages = result["messages"]

      user_messages = Enum.filter(messages, &(&1["role"] == "user"))
      assert length(user_messages) == 2

      tool_result_msg = List.last(user_messages)
      assert is_list(tool_result_msg["content"])
      assert length(tool_result_msg["content"]) == 2

      [result1, result2] = tool_result_msg["content"]
      assert result1["toolResult"]["toolUseId"] == "call_1"
      assert result2["toolResult"]["toolUseId"] == "call_2"
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

      assert result.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               total_tokens: 15,
               cached_tokens: 0,
               reasoning_tokens: 0
             }

      assert result.message.role == :assistant
      assert [%ContentPart{type: :text, text: "Hello!"}] = result.message.content
    end

    test "falls back unknown response role to assistant" do
      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "unexpected_role",
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
      assert %ReqLLM.StreamChunk{type: :content, text: "Hello"} = result
    end

    test "parses messageStop with finish reason" do
      chunk = %{
        "messageStop" => %{
          "stopReason" => "end_turn"
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")
      assert %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: :stop}} = result
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

      assert %ReqLLM.StreamChunk{
               type: :meta,
               metadata: %{usage: %{input_tokens: 100, output_tokens: 50}}
             } = result
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

  describe "structured output (:object operation)" do
    test "format_request creates structured_output tool for :object operation" do
      schema = [
        name: [type: :string, required: true, doc: "Person's full name"],
        age: [type: :pos_integer, required: true, doc: "Person's age in years"],
        occupation: [type: :string, doc: "Person's job or profession"]
      ]

      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      context = %ReqLLM.Context{
        messages: [%Message{role: :user, content: "Generate a software engineer profile"}]
      }

      result =
        Converse.format_request(
          "test-model",
          context,
          operation: :object,
          compiled_schema: compiled_schema,
          max_tokens: 500,
          formatter_module: ReqLLM.Providers.AmazonBedrock.Anthropic
        )

      # Should include toolConfig with structured_output tool
      assert result["toolConfig"]["tools"]
      assert length(result["toolConfig"]["tools"]) == 1

      tool = List.first(result["toolConfig"]["tools"])
      assert tool["toolSpec"]["name"] == "structured_output"

      assert tool["toolSpec"]["description"] ==
               "Generate structured output matching the provided schema"

      # Should have inputSchema with the user's schema
      assert tool["toolSpec"]["inputSchema"]["json"]["type"] == "object"
      assert tool["toolSpec"]["inputSchema"]["json"]["properties"]["name"]["type"] == "string"
      assert tool["toolSpec"]["inputSchema"]["json"]["properties"]["age"]["type"] == "integer"
      assert tool["toolSpec"]["inputSchema"]["json"]["properties"]["age"]["minimum"] == 1
      assert tool["toolSpec"]["inputSchema"]["json"]["required"] == ["name", "age"]

      # Should have tool choice forcing structured_output
      assert result["toolConfig"]["toolChoice"]["tool"]["name"] == "structured_output"
    end

    test "parse_response extracts object from tool call for :object operation" do
      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "toolUse" => %{
                  "toolUseId" => "call_abc",
                  "name" => "structured_output",
                  "input" => %{
                    "name" => "Alice Johnson",
                    "age" => 29,
                    "occupation" => "Software Engineer"
                  }
                }
              }
            ]
          }
        },
        "stopReason" => "tool_use",
        "usage" => %{
          "inputTokens" => 451,
          "outputTokens" => 69
        }
      }

      {:ok, result} = Converse.parse_response(response_body, operation: :object, id: "test")

      assert result.finish_reason == :tool_calls

      # For :object operation, should extract and set the object field
      assert result.object == %{
               "name" => "Alice Johnson",
               "age" => 29,
               "occupation" => "Software Engineer"
             }
    end

    test "parse_response returns response without object extraction for :chat operation" do
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

      {:ok, result} = Converse.parse_response(response_body, operation: :chat, id: "test")

      assert result.finish_reason == :stop
      # Should not have object field for :chat operation
      assert is_nil(result.object)
    end

    test "add_tool_choice converts Anthropic format to Converse format" do
      context = %ReqLLM.Context{
        messages: [%Message{role: :user, content: "Test"}]
      }

      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "test_tool",
          description: "Test",
          parameter_schema: [location: [type: :string]],
          callback: fn _ -> {:ok, "result"} end
        )

      result =
        Converse.format_request(
          "test-model",
          context,
          tools: [tool],
          tool_choice: %{type: "tool", name: "test_tool"},
          formatter_module: ReqLLM.Providers.AmazonBedrock.Anthropic
        )

      # Should convert to Converse format
      assert result["toolConfig"]["toolChoice"]["tool"]["name"] == "test_tool"
    end
  end
end
