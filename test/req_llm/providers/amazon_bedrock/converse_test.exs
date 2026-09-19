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

      refute Map.has_key?(result, "guardrailConfig")
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

    test "formats request with multiple system messages" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :system, content: "Talk like a pirate"},
          %Message{role: :user, content: "Hello"},
          %Message{role: :system, content: "Respond in verses"}
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["system"] == [
               %{"text" => "Talk like a pirate"},
               %{"text" => "\n\n"},
               %{"text" => "Respond in verses"}
             ]

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
                       "propertyOrdering" => ["location"],
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

    test "omits trace from guardrail config when not set" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Hello"}]}

      result =
        Converse.format_request("test-model", context,
          guardrail_identifier: "abc123",
          guardrail_version: "DRAFT"
        )

      assert result["guardrailConfig"] == %{
               "guardrailIdentifier" => "abc123",
               "guardrailVersion" => "DRAFT"
             }
    end

    test "raises when guardrail identifier is set without a version" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Hello"}]}

      assert_raise ArgumentError, ~r/guardrail_version/, fn ->
        Converse.format_request("test-model", context, guardrail_identifier: "abc123")
      end
    end
  end

  describe "reasoning round-trip" do
    alias ReqLLM.Message.ReasoningDetails

    defp tool_call, do: ReqLLM.ToolCall.new("call_1", "get_weather", "{}")

    test "replays signed reasoning before assistant content" do
      details = [
        %ReasoningDetails{
          text: "thought",
          signature: "sig",
          encrypted?: true,
          provider: :amazon_bedrock,
          index: 0
        },
        %ReasoningDetails{text: "unsigned", signature: nil, provider: :amazon_bedrock, index: 1}
      ]

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: "Calling",
            tool_calls: [tool_call()],
            reasoning_details: details
          },
          %Message{role: :tool, tool_call_id: "call_1", content: "sunny"}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant, _] = result["messages"]

      assert [
               %{
                 "reasoningContent" => %{
                   "reasoningText" => %{"text" => "thought", "signature" => "sig"}
                 }
               },
               %{"text" => "Calling"},
               %{"toolUse" => _}
             ] = assistant["content"]
    end

    test "replays redacted reasoning" do
      details = [
        %ReasoningDetails{
          encrypted?: true,
          provider: :amazon_bedrock,
          index: 0,
          provider_data: %{"redactedContent" => "abc="}
        }
      ]

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{role: :assistant, content: "Done", reasoning_details: details}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant] = result["messages"]

      assert assistant["content"] == [
               %{"reasoningContent" => %{"redactedContent" => "abc="}},
               %{"text" => "Done"}
             ]
    end

    test "does not replay thinking parts without reasoning details" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: [ContentPart.thinking("x"), ContentPart.text("Done")]
          }
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant] = result["messages"]

      assert assistant["content"] == [%{"text" => "Done"}]
    end

    test "parses reasoningContent into thinking content and reasoning details" do
      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "reasoningContent" => %{
                  "reasoningText" => %{"text" => "thought", "signature" => "sig"}
                }
              },
              %{"reasoningContent" => %{"redactedContent" => "abc="}},
              %{"text" => "Answer"}
            ]
          }
        },
        "stopReason" => "end_turn"
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test-model")

      assert [
               %ContentPart{type: :thinking, text: "thought"},
               %ContentPart{type: :text, text: "Answer"}
             ] =
               result.message.content

      assert [
               %ReasoningDetails{
                 text: "thought",
                 signature: "sig",
                 encrypted?: true,
                 provider: :amazon_bedrock,
                 format: "bedrock-converse-v1",
                 index: 0
               },
               %ReasoningDetails{
                 text: nil,
                 signature: nil,
                 encrypted?: true,
                 index: 1,
                 provider_data: %{"redactedContent" => "abc="}
               }
             ] = result.message.reasoning_details
    end

    test "does not replay reasoning from other providers" do
      details = [
        %ReasoningDetails{
          text: "thought",
          signature: "sig",
          encrypted?: true,
          provider: :google,
          index: 0
        },
        %ReasoningDetails{
          text: "kept",
          signature: "sig2",
          encrypted?: true,
          provider: :anthropic,
          index: 1
        }
      ]

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{role: :assistant, content: "Done", reasoning_details: details}
        ]
      }

      result = Converse.format_request("test-model", context, [])
      [_, assistant] = result["messages"]

      assert [
               %{
                 "reasoningContent" => %{
                   "reasoningText" => %{"text" => "kept", "signature" => "sig2"}
                 }
               },
               %{"text" => "Done"}
             ] = assistant["content"]
    end

    test "flushes reasoning blocks that never stopped" do
      events = [
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"text" => "thought"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"signature" => "sig"}}
          }
        }
      ]

      {_chunks, state} =
        Enum.flat_map_reduce(
          events,
          Converse.init_stream_state(),
          &Converse.decode_stream_event/2
        )

      {[chunk], state} = Converse.flush_stream_state(state)

      assert %ReqLLM.StreamChunk{
               metadata: %{
                 reasoning_details: [%ReasoningDetails{text: "thought", signature: "sig"}]
               }
             } =
               chunk

      assert Converse.flush_stream_state(state) == {[], state}
    end

    test "numbers reasoning details independently of text block indices" do
      events = [
        %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "Hi"}}},
        %{"contentBlockStop" => %{"contentBlockIndex" => 0}},
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 3,
            "delta" => %{"reasoningContent" => %{"text" => "a"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 3,
            "delta" => %{"reasoningContent" => %{"signature" => "s1"}}
          }
        },
        %{"contentBlockStop" => %{"contentBlockIndex" => 3}},
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 5,
            "delta" => %{"reasoningContent" => %{"text" => "b"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 5,
            "delta" => %{"reasoningContent" => %{"signature" => "s2"}}
          }
        },
        %{"contentBlockStop" => %{"contentBlockIndex" => 5}}
      ]

      {chunks, _state} =
        Enum.flat_map_reduce(
          events,
          Converse.init_stream_state(),
          &Converse.decode_stream_event/2
        )

      indices =
        for %ReqLLM.StreamChunk{type: :meta, metadata: %{reasoning_details: [detail]}} <- chunks,
            do: detail.index

      assert indices == [0, 1]
    end

    test "streams reasoning deltas and emits details on contentBlockStop" do
      events = [
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"text" => "tho"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"text" => "ught"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"signature" => "sig"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"reasoningContent" => %{"signature" => "_test"}}
          }
        },
        %{"contentBlockStop" => %{"contentBlockIndex" => 0}},
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 1,
            "delta" => %{"reasoningContent" => %{"redactedContent" => Base.encode64("a")}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 1,
            "delta" => %{"reasoningContent" => %{"redactedContent" => Base.encode64("b")}}
          }
        },
        %{"contentBlockStop" => %{"contentBlockIndex" => 1}},
        %{"contentBlockDelta" => %{"contentBlockIndex" => 2, "delta" => %{"text" => "Answer"}}},
        %{"contentBlockStop" => %{"contentBlockIndex" => 2}}
      ]

      {chunks, _state} =
        Enum.flat_map_reduce(events, Converse.init_stream_state(), fn event, state ->
          Converse.decode_stream_event(event, state)
        end)

      assert [
               %ReqLLM.StreamChunk{type: :thinking, text: "tho"},
               %ReqLLM.StreamChunk{type: :thinking, text: "ught"},
               %ReqLLM.StreamChunk{type: :meta, metadata: %{reasoning_details: [signed]}},
               %ReqLLM.StreamChunk{type: :meta, metadata: %{reasoning_details: [redacted]}},
               %ReqLLM.StreamChunk{type: :content, text: "Answer"}
             ] = chunks

      assert %ReasoningDetails{text: "thought", signature: "sig_test", encrypted?: true, index: 0} =
               signed

      expected_redacted = Base.encode64("ab")

      assert %ReasoningDetails{
               text: nil,
               index: 1,
               provider_data: %{"redactedContent" => ^expected_redacted}
             } =
               redacted
    end
  end

  describe "guard content" do
    defp guarded_request(parts) do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: parts}]}
      Converse.format_request("test-model", context, [])
    end

    test "wraps a guarded text part" do
      result = guarded_request([ContentPart.text("Hi", %{guard_content: true})])

      assert hd(result["messages"])["content"] == [
               %{"guardContent" => %{"text" => %{"text" => "Hi"}}}
             ]
    end

    test "carries qualifiers as strings" do
      result =
        guarded_request([
          ContentPart.text("Paris is in France.", %{
            guard_content: %{qualifiers: [:grounding_source, "query"]}
          })
        ])

      assert hd(result["messages"])["content"] == [
               %{
                 "guardContent" => %{
                   "text" => %{
                     "text" => "Paris is in France.",
                     "qualifiers" => ["grounding_source", "query"]
                   }
                 }
               }
             ]
    end

    test "accepts string keys" do
      result =
        guarded_request([
          ContentPart.text("Hi", %{"guard_content" => %{"qualifiers" => ["query"]}})
        ])

      assert [%{"guardContent" => %{"text" => %{"qualifiers" => ["query"]}}}] =
               hd(result["messages"])["content"]
    end

    test "wraps guarded png and jpeg images" do
      for {media_type, format} <- [{"image/png", "png"}, {"image/jpeg", "jpeg"}] do
        result =
          guarded_request([ContentPart.image(<<1, 2>>, media_type, %{guard_content: true})])

        assert hd(result["messages"])["content"] == [
                 %{
                   "guardContent" => %{
                     "image" => %{"format" => format, "source" => %{"bytes" => "AQI="}}
                   }
                 }
               ]
      end
    end

    test "guards system message parts" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: [
              ContentPart.text("Only list songs.", %{guard_content: true}),
              ContentPart.text("Be brief.")
            ]
          },
          %Message{role: :user, content: "Hi"}
        ]
      }

      result = Converse.format_request("test-model", context, [])

      assert result["system"] == [
               %{"guardContent" => %{"text" => %{"text" => "Only list songs."}}},
               %{"text" => "Be brief."}
             ]
    end

    test "leaves unguarded parts alone" do
      result =
        guarded_request([
          ContentPart.text("plain"),
          ContentPart.text("off", %{guard_content: false})
        ])

      assert hd(result["messages"])["content"] == [%{"text" => "plain"}, %{"text" => "off"}]
    end

    test "raises on guarded tool result parts" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [ReqLLM.ToolCall.new("call_1", "get_weather", "{}")]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: [ContentPart.text("sunny", %{guard_content: true})]
          }
        ]
      }

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/tool results/, fn ->
        Converse.format_request("test-model", context, [])
      end
    end

    test "raises on malformed hints" do
      for metadata <- [
            %{guard_content: "yes"},
            %{guard_content: %{qualifiers: "query"}},
            %{guard_content: %{qualifiers: [1]}}
          ] do
        assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
          guarded_request([ContentPart.text("Hi", metadata)])
        end
      end
    end

    test "raises on guarded parts that cannot be encoded" do
      for part <- [
            ContentPart.text("", %{guard_content: true}),
            ContentPart.image_url("https://example.com/a.png", %{guard_content: true})
          ] do
        assert_raise ReqLLM.Error.Invalid.Parameter, ~r/non-empty text or image/, fn ->
          guarded_request([part])
        end
      end
    end

    test "raises on guarded images that AWS does not accept" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        guarded_request([ContentPart.image(<<1>>, "image/gif", %{guard_content: true})])
      end

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        guarded_request([
          ContentPart.image(<<1>>, "image/png", %{guard_content: %{qualifiers: [:query]}})
        ])
      end
    end
  end

  describe "parse_response/2" do
    test "parses citationsContent into text and annotations" do
      title = %{
        "title" => "MyDocument",
        "sourceContent" => [%{"text" => "Test PDF Document"}],
        "location" => %{"documentPage" => %{"documentIndex" => 0, "start" => 1, "end" => 2}}
      }

      page = %{
        "title" => "MyDocument",
        "sourceContent" => [%{"text" => "one page"}],
        "location" => %{"documentChar" => %{"documentIndex" => 0, "start" => 18, "end" => 26}}
      }

      response_body = %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "citationsContent" => %{
                  "content" => [
                    %{"text" => "This document contains "},
                    %{"text" => "\"Test PDF Document\""}
                  ],
                  "citations" => [title]
                }
              },
              %{"text" => " as its text, on "},
              %{"citationsContent" => %{"citations" => [page, title]}}
            ]
          }
        },
        "stopReason" => "end_turn",
        "usage" => %{"inputTokens" => 10, "outputTokens" => 5}
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test-model")

      assert ReqLLM.Response.text(result) ==
               "This document contains \"Test PDF Document\" as its text, on "

      cited_length = String.length("This document contains \"Test PDF Document\"")
      total_length = String.length(ReqLLM.Response.text(result))

      assert ReqLLM.Response.annotations(result) == [
               Map.merge(title, %{"start_index" => 0, "end_index" => cited_length}),
               Map.merge(page, %{"start_index" => total_length, "end_index" => total_length}),
               Map.merge(title, %{"start_index" => total_length, "end_index" => total_length})
             ]
    end

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
      assert result.provider_meta == %{}

      assert result.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               total_tokens: 15,
               cache_read_tokens: 0,
               cache_write_tokens: 0,
               cached_tokens: 0,
               cache_creation_tokens: 0,
               reasoning_tokens: 0,
               input_includes_cached: false
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
        {"content_filtered", :content_filter},
        {"guardrail_intervened", :content_filter}
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

    test "exposes guardrail trace in provider_meta" do
      trace = %{"guardrail" => %{"inputAssessment" => %{"g1" => %{"topicPolicy" => %{}}}}}

      response_body = %{
        "output" => %{
          "message" => %{"role" => "assistant", "content" => [%{"text" => "Blocked"}]}
        },
        "stopReason" => "guardrail_intervened",
        "trace" => trace
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test")

      assert result.finish_reason == :content_filter
      assert result.provider_meta.trace == trace
    end

    test "splits cache reads and writes and keeps total as input plus output" do
      response_body = %{
        "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "ok"}]}},
        "stopReason" => "end_turn",
        "usage" => %{
          "inputTokens" => 12,
          "outputTokens" => 5,
          "cacheReadInputTokens" => 4000,
          "cacheWriteInputTokens" => 900
        }
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test")

      assert result.usage.input_tokens == 12
      assert result.usage.cache_read_tokens == 4000
      assert result.usage.cache_write_tokens == 900
      assert result.usage.cached_tokens == 4000
      assert result.usage.cache_creation_tokens == 900
      assert result.usage.total_tokens == 17
      assert result.usage.input_includes_cached == false
    end

    test "exposes cacheDetails next to the guardrail trace" do
      trace = %{"guardrail" => %{}}
      cache_details = [%{"ttl" => "5m", "inputTokens" => 900}]

      response_body = %{
        "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "ok"}]}},
        "stopReason" => "end_turn",
        "trace" => trace,
        "usage" => %{"inputTokens" => 1, "outputTokens" => 1, "cacheDetails" => cache_details}
      }

      {:ok, result} = Converse.parse_response(response_body, model: "test")

      assert result.provider_meta == %{trace: trace, cache_details: cache_details}
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses citation deltas as annotations" do
      citation = %{
        "title" => "MyDocument",
        "sourceContent" => [%{"text" => "Test PDF Document"}],
        "location" => %{"documentPage" => %{"documentIndex" => 0, "start" => 1, "end" => 2}}
      }

      chunk = %{
        "contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"citation" => citation}}
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")
      expected = Map.put(citation, "content_block_index", 0)
      assert %ReqLLM.StreamChunk{type: :meta, metadata: %{annotations: [^expected]}} = result
    end

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

    test "parses metadata with split cache usage and cacheDetails" do
      cache_details = [%{"ttl" => "1h", "inputTokens" => 900}]

      chunk = %{
        "metadata" => %{
          "usage" => %{
            "inputTokens" => 12,
            "outputTokens" => 5,
            "cacheReadInputTokens" => 4000,
            "cacheWriteInputTokens" => 900,
            "cacheDetails" => cache_details
          },
          "trace" => %{"guardrail" => %{}}
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")

      assert result.metadata.usage.cache_read_tokens == 4000
      assert result.metadata.usage.cache_write_tokens == 900
      assert result.metadata.usage.cached_tokens == 4000
      assert result.metadata.usage.cache_creation_tokens == 900

      assert result.metadata.provider_meta == %{
               trace: %{"guardrail" => %{}},
               cache_details: cache_details
             }
    end

    test "parses metadata with guardrail trace" do
      trace = %{"guardrail" => %{"outputAssessments" => %{}}}

      chunk = %{
        "metadata" => %{
          "usage" => %{"inputTokens" => 1, "outputTokens" => 2},
          "trace" => trace
        }
      }

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")

      assert %ReqLLM.StreamChunk{type: :meta, metadata: metadata} = result
      assert metadata.usage.input_tokens == 1
      assert metadata.provider_meta == %{trace: trace}
    end

    test "parses metadata with only a trace" do
      chunk = %{"metadata" => %{"trace" => %{"guardrail" => %{}}}}

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")

      assert %ReqLLM.StreamChunk{type: :meta, metadata: %{provider_meta: %{trace: _}}} = result
      refute Map.has_key?(result.metadata, :usage)
    end

    test "parses messageStop with guardrail_intervened stop reason" do
      chunk = %{"messageStop" => %{"stopReason" => "guardrail_intervened"}}

      {:ok, result} = Converse.parse_stream_chunk(chunk, "test-model")

      assert %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: :content_filter}} =
               result
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

  describe "documents and video" do
    @pdf "%PDF-1.4 test"

    test "sends a file part as a document block" do
      part = ContentPart.file(@pdf, "MyDocument.pdf", "application/pdf")

      assert encode_part(part) == %{
               "document" => %{
                 "format" => "pdf",
                 "name" => "MyDocument",
                 "source" => %{"bytes" => Base.encode64(@pdf)}
               }
             }
    end

    test "infers the format from the filename when the media type is the default" do
      assert %{"video" => %{"format" => "mp4"}} =
               encode_part(ContentPart.file("AQI=", "clip.mp4"))

      assert %{"document" => %{"format" => "pdf"}} =
               encode_part(ContentPart.file(@pdf, "report.pdf"))
    end

    test "prefers the media type over the filename extension" do
      part = ContentPart.file("a,b", "export.bin", "text/csv")

      assert %{"document" => %{"format" => "csv"}} = encode_part(part)
    end

    test "ignores media type parameters" do
      part = ContentPart.file("notes", "notes.txt", "text/plain; charset=utf-8")

      assert %{"document" => %{"format" => "txt"}} = encode_part(part)
    end

    test "passes unknown formats through for Amazon to refuse" do
      assert %{"document" => %{"format" => "rtf"}} =
               encode_part(ContentPart.file("x", "notes.rtf"))
    end

    test "names a document from its title metadata or its filename and passes context" do
      part = %{
        ContentPart.file(@pdf, "Q3_report.v2.pdf")
        | metadata: %{title: "Quarterly report (Q3)", context: "Sales figures"}
      }

      assert %{"document" => %{"name" => "Quarterly report (Q3)", "context" => "Sales figures"}} =
               encode_part(part)

      assert %{"document" => %{"name" => "Q3 report v2"}} =
               encode_part(ContentPart.file(@pdf, "Q3_report.v2.pdf"))
    end

    test "uses a neutral name when the sanitized document name is empty" do
      assert %{"document" => %{"name" => "Document"}} =
               encode_part(ContentPart.file(@pdf, "!!!.pdf", "application/pdf"))

      part = %{
        ContentPart.file(@pdf, "report.pdf", "application/pdf")
        | metadata: %{title: "!!!"}
      }

      assert %{"document" => %{"name" => "Document"}} = encode_part(part)
    end

    test "rejects a document without a related text prompt" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :user,
            content: [ContentPart.file(@pdf, "report.pdf", "application/pdf")]
          }
        ]
      }

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/related text prompt/, fn ->
        Converse.format_request("test-model", context, [])
      end
    end

    test "rejects attachments in system prompts" do
      video = %{ContentPart.video_url("s3://bucket/video.mp4") | media_type: "video/mp4"}

      for part <- [
            ContentPart.file(@pdf, "report.pdf", "application/pdf"),
            ContentPart.image(<<1>>, "image/png"),
            video
          ] do
        context = %ReqLLM.Context{
          messages: [
            %Message{role: :system, content: [part]},
            %Message{role: :user, content: "Hello"}
          ]
        }

        assert_raise ReqLLM.Error.Invalid.Parameter, ~r/system prompts/, fn ->
          Converse.format_request("test-model", context, [])
        end
      end
    end

    test "enables citations on a document" do
      document = fn citations ->
        ContentPart.file(@pdf, "MyDocument.pdf", "application/pdf", %{citations: citations})
      end

      assert %{"document" => %{"citations" => %{"enabled" => true}}} =
               encode_part(document.(true))

      assert_raise ReqLLM.Error.Invalid.Parameter, fn -> encode_part(document.("yes")) end
    end

    test "reads sources from S3" do
      video = %{
        ContentPart.video_url("s3://amzn-s3-demo-bucket/myVideo", %{bucket_owner: "111122223333"})
        | media_type: "video/mp4"
      }

      assert encode_part(video) == %{
               "video" => %{
                 "format" => "mp4",
                 "source" => %{
                   "s3Location" => %{
                     "uri" => "s3://amzn-s3-demo-bucket/myVideo",
                     "bucketOwner" => "111122223333"
                   }
                 }
               }
             }

      document = %ContentPart{
        type: :file,
        url: "s3://amzn-s3-demo-bucket/myDocument",
        media_type: "application/pdf",
        metadata: %{title: "MyDocument"}
      }

      assert encode_part(document) == %{
               "document" => %{
                 "format" => "pdf",
                 "name" => "MyDocument",
                 "source" => %{"s3Location" => %{"uri" => "s3://amzn-s3-demo-bucket/myDocument"}}
               }
             }

      assert %{"image" => %{"format" => "png", "source" => %{"s3Location" => _}}} =
               encode_part(ContentPart.image_url("s3://amzn-s3-demo-bucket/photo.png"))
    end

    test "raises on sources Converse cannot fetch" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        encode_part(ContentPart.image_url("https://example.com/photo.png"))
      end

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        encode_part(ContentPart.file_id("file_123"))
      end
    end

    test "sends documents inside tool results" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :tool,
            tool_call_id: "call_doc",
            content: [
              ContentPart.text("Here is the file:"),
              ContentPart.file(@pdf, "MyDocument.pdf", "application/pdf")
            ]
          }
        ]
      }

      [%{"content" => [%{"toolResult" => %{"content" => content}}]}] =
        Converse.format_request("test-model", context, [])["messages"]

      assert [%{"text" => "Here is the file:"}, %{"document" => %{"name" => "MyDocument"}}] =
               content
    end

    defp encode_part(part) do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :user,
            content: [ContentPart.text("Describe the attachment."), part]
          }
        ]
      }

      [%{"content" => [%{"text" => "Describe the attachment."}, block]}] =
        Converse.format_request("test-model", context, [])["messages"]

      block
    end
  end

  describe "prompt caching" do
    @cp %{"cachePoint" => %{"type" => "default"}}

    defp tool do
      ReqLLM.Tool.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [location: [type: :string, required: true]],
        callback: fn _ -> {:ok, "sunny"} end
      )
    end

    defp cached_context do
      %ReqLLM.Context{
        messages: [
          %Message{role: :system, content: "You are helpful"},
          %Message{role: :user, content: "Hello"},
          %Message{role: :assistant, content: "Hi"},
          %Message{role: :user, content: "Weather?"}
        ]
      }
    end

    test "emits nothing without prompt_cache" do
      result = Converse.format_request("anthropic.claude", cached_context(), tools: [tool()])

      refute Enum.any?(result["system"], &match?(%{"cachePoint" => _}, &1))
      refute Enum.any?(result["toolConfig"]["tools"], &match?(%{"cachePoint" => _}, &1))
    end

    test "appends tools, system, and message checkpoints" do
      result =
        Converse.format_request("anthropic.claude", cached_context(),
          tools: [tool()],
          prompt_cache: true,
          cache_messages: true
        )

      assert List.last(result["toolConfig"]["tools"]) == @cp
      assert result["system"] == [%{"text" => "You are helpful"}, @cp]
      assert List.last(result["messages"])["content"] == [%{"text" => "Weather?"}, @cp]
    end

    test "reads options nested under provider_options with a ttl" do
      result =
        Converse.format_request("anthropic.claude", cached_context(),
          provider_options: [prompt_cache: true, prompt_cache_ttl: "1h"]
        )

      assert List.last(result["system"]) == %{
               "cachePoint" => %{"type" => "default", "ttl" => "1h"}
             }
    end

    test "skips the tools checkpoint for Nova" do
      result =
        Converse.format_request("us.amazon.nova-pro-v1:0", cached_context(),
          tools: [tool()],
          prompt_cache: true
        )

      refute match?(%{"cachePoint" => _}, List.last(result["toolConfig"]["tools"]))
      assert List.last(result["system"]) == @cp
    end

    test "emits an explicit checkpoint after a content part with cache_control metadata" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: [
              ContentPart.text("Stable", %{cache_control: %{type: "ephemeral", ttl: "1h"}}),
              ContentPart.text("Dynamic")
            ]
          },
          %Message{
            role: :user,
            content: [ContentPart.text("Hi", %{"cache_control" => %{"type" => "ephemeral"}})]
          }
        ]
      }

      result = Converse.format_request("anthropic.claude", context, [])

      assert result["system"] == [
               %{"text" => "Stable"},
               %{"cachePoint" => %{"type" => "default", "ttl" => "1h"}},
               %{"text" => "Dynamic"}
             ]

      assert hd(result["messages"])["content"] == [%{"text" => "Hi"}, @cp]
    end

    test "does not duplicate an explicit checkpoint at the system boundary" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: [ContentPart.text("Stable", %{cache_control: %{type: "ephemeral"}})]
          },
          %Message{role: :user, content: "Hi"}
        ]
      }

      result = Converse.format_request("anthropic.claude", context, prompt_cache: true)

      assert result["system"] == [%{"text" => "Stable"}, @cp]
    end

    test "lifts a tool result cache hint to a sibling checkpoint" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: "",
            tool_calls: [ReqLLM.ToolCall.new("call_1", "get_weather", "{}")]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: [ContentPart.text("sunny", %{cache_control: %{type: "ephemeral"}})]
          }
        ]
      }

      result = Converse.format_request("anthropic.claude", context, tools: [tool()])
      tool_result_message = List.last(result["messages"])

      assert [%{"toolResult" => %{"content" => [%{"text" => "sunny"}]}}, @cp] =
               tool_result_message["content"]
    end

    test "places a message-level cache_control hint after the whole message" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: "Stable",
            metadata: %{cache_control: %{type: "ephemeral", ttl: "1h"}}
          },
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [ReqLLM.ToolCall.new("call_1", "get_weather", "{}")],
            metadata: %{cache_control: %{type: "ephemeral"}}
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: "sunny",
            metadata: %{cache_control: %{type: "ephemeral"}}
          },
          %Message{
            role: :user,
            content: "Thanks",
            metadata: %{"cache_control" => %{"type" => "ephemeral"}}
          }
        ]
      }

      result = Converse.format_request("anthropic.claude", context, tools: [tool()])

      assert result["system"] == [
               %{"text" => "Stable"},
               %{"cachePoint" => %{"type" => "default", "ttl" => "1h"}}
             ]

      [_hi, assistant, tool_result, thanks] = result["messages"]
      assert [%{"toolUse" => _}, @cp] = assistant["content"]
      assert [%{"toolResult" => _}, @cp] = tool_result["content"]
      assert thanks["content"] == [%{"text" => "Thanks"}, @cp]
    end

    test "does not duplicate a message-level hint on the cache_messages position" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi", metadata: %{cache_control: %{type: "ephemeral"}}}
        ]
      }

      result =
        Converse.format_request("anthropic.claude", context,
          prompt_cache: true,
          cache_messages: true
        )

      assert hd(result["messages"])["content"] == [%{"text" => "Hi"}, @cp]
    end

    test "drops an empty system message even when it carries a cache hint" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: [ContentPart.text("")],
            metadata: %{cache_control: %{type: "ephemeral"}}
          },
          %Message{role: :user, content: "Hi"}
        ]
      }

      result = Converse.format_request("anthropic.claude", context, [])

      refute Map.has_key?(result, "system")
    end

    test "emits one checkpoint when the last part and the message both carry a hint" do
      hint = %{cache_control: %{type: "ephemeral"}}

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: [ContentPart.text("Hi", hint)], metadata: hint}
        ]
      }

      result = Converse.format_request("anthropic.claude", context, [])

      assert hd(result["messages"])["content"] == [%{"text" => "Hi"}, @cp]
    end

    test "still merges consecutive tool results that carry checkpoints" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: "",
            tool_calls: [
              ReqLLM.ToolCall.new("call_1", "get_weather", "{}"),
              ReqLLM.ToolCall.new("call_2", "get_weather", "{}")
            ]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: [ContentPart.text("sunny", %{cache_control: %{type: "ephemeral"}})]
          },
          %Message{role: :tool, tool_call_id: "call_2", content: "rainy"}
        ]
      }

      result = Converse.format_request("anthropic.claude", context, tools: [tool()])
      [_, _, merged] = result["messages"]

      assert [%{"toolResult" => _}, @cp, %{"toolResult" => _}] = merged["content"]
    end

    test "drops nil system blocks" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :system, content: [ContentPart.text(""), ContentPart.text("Keep")]},
          %Message{role: :user, content: "Hi"}
        ]
      }

      result = Converse.format_request("anthropic.claude", context, prompt_cache: true)

      assert result["system"] == [%{"text" => "Keep"}, @cp]
    end

    test "marks the cache_messages position and ignores one out of range" do
      result =
        Converse.format_request("anthropic.claude", cached_context(),
          prompt_cache: true,
          cache_messages: 1
        )

      [_hello, hi, _weather] = result["messages"]
      assert hi["content"] == [%{"text" => "Hi"}, @cp]

      result =
        Converse.format_request("anthropic.claude", cached_context(),
          prompt_cache: true,
          cache_messages: 7
        )

      refute Enum.any?(
               result["messages"],
               &match?(%{"cachePoint" => _}, List.last(&1["content"]))
             )
    end

    test "rejects an unsupported cache_control ttl" do
      context = %ReqLLM.Context{
        messages: [
          %Message{
            role: :user,
            content: [ContentPart.text("Hi", %{cache_control: %{ttl: "30m"}})]
          }
        ]
      }

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/ttl/, fn ->
        Converse.format_request("anthropic.claude", context, [])
      end
    end

    test "rejects a 1h checkpoint after a 5m one" do
      explicit_only = %ReqLLM.Context{
        messages: [
          %Message{role: :system, content: [ContentPart.text("Stable", %{cache_control: %{}})]},
          %Message{role: :user, content: [ContentPart.text("Hi", %{cache_control: %{ttl: "1h"}})]}
        ]
      }

      automatic_then_explicit = %ReqLLM.Context{
        messages: [
          %Message{
            role: :system,
            content: [ContentPart.text("Stable", %{cache_control: %{ttl: "1h"}})]
          },
          %Message{role: :user, content: "Hi"}
        ]
      }

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/1h/, fn ->
        Converse.format_request("anthropic.claude", explicit_only, [])
      end

      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/1h/, fn ->
        Converse.format_request("anthropic.claude", automatic_then_explicit,
          tools: [tool()],
          prompt_cache: true
        )
      end
    end
  end

  describe "Anthropic request fields" do
    @anthropic ReqLLM.Providers.AmazonBedrock.Anthropic
    @meta ReqLLM.Providers.AmazonBedrock.Meta

    test "caller additional fields win over top_k and anthropic_beta" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Hi"}]}

      result =
        Converse.format_request("anthropic.claude", context,
          formatter_module: @anthropic,
          top_k: 5,
          provider_options: [
            anthropic_beta: ["a"],
            additional_model_request_fields: %{
              top_k: 7,
              anthropic_beta: ["b"],
              thinking: %{type: "enabled"}
            }
          ]
        )

      assert result["additionalModelRequestFields"] == %{
               "top_k" => 7,
               "anthropic_beta" => ["b"],
               "thinking" => %{type: "enabled"}
             }
    end

    test "Meta gets the caller fields and a normalized tool schema" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Hi"}]}

      result =
        Converse.format_request("meta.llama", context,
          formatter_module: @meta,
          tools: [tool()],
          top_k: 5,
          provider_options: [additional_model_request_fields: %{max_gen_len: 10}]
        )

      assert result["additionalModelRequestFields"] == %{"max_gen_len" => 10}

      [%{"toolSpec" => %{"inputSchema" => %{"json" => schema}}}] = result["toolConfig"]["tools"]
      refute Map.has_key?(schema, "additionalProperties")
    end

    test "omits toolChoice without tools and rejects unsupported choices" do
      context = %ReqLLM.Context{messages: [%Message{role: :user, content: "Hi"}]}

      result =
        Converse.format_request("anthropic.claude", context,
          formatter_module: @anthropic,
          tool_choice: :auto
        )

      refute Map.has_key?(result, "toolConfig")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Converse.format_request("anthropic.claude", context,
          formatter_module: @anthropic,
          tools: [tool()],
          tool_choice: :bogus
        )
      end
    end

    test "keeps tool result errors for Claude and Nova only" do
      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: "Hi"},
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [ReqLLM.ToolCall.new("call_1", "get_weather", "{}")]
          },
          %Message{
            role: :tool,
            tool_call_id: "call_1",
            content: [ContentPart.text("boom")],
            metadata: %{is_error: true}
          }
        ]
      }

      status = fn model_id, formatter ->
        result = Converse.format_request(model_id, context, formatter_module: formatter)
        [%{"toolResult" => tool_result}] = List.last(result["messages"])["content"]
        tool_result["status"]
      end

      assert status.("anthropic.claude", @anthropic) == "error"
      assert status.("us.amazon.nova-pro-v1:0", Converse) == "error"
      assert status.("meta.llama", @meta) == nil
    end
  end
end
