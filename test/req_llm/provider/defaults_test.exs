defmodule ReqLLM.Provider.DefaultsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Provider.Defaults.ResponseBuilder
  alias ReqLLM.StreamChunk

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

    test "preserves cache_control metadata in content blocks" do
      content_with_cache = %ContentPart{
        type: :text,
        text: "Cached content",
        metadata: %{cache_control: %{type: "ephemeral"}}
      }

      message = %Message{
        role: :user,
        content: [
          content_with_cache,
          %ContentPart{type: :text, text: "Normal content"}
        ]
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      [cached_block, normal_block] = encoded_message.content

      assert cached_block == %{
               type: "text",
               text: "Cached content",
               cache_control: %{type: "ephemeral"}
             }

      assert normal_block == %{type: "text", text: "Normal content"}
    end

    test "handles cache_control with TTL in metadata" do
      content_with_ttl = %ContentPart{
        type: :text,
        text: "Cached with TTL",
        metadata: %{cache_control: %{type: "ephemeral", ttl: 3600}}
      }

      message = %Message{role: :system, content: [content_with_ttl]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages

      assert encoded_message.content == [
               %{
                 type: "text",
                 text: "Cached with TTL",
                 cache_control: %{type: "ephemeral", ttl: 3600}
               }
             ]
    end

    test "handles string key cache_control in metadata" do
      content_with_string_key = %ContentPart{
        type: :text,
        text: "String key cache",
        metadata: %{"cache_control" => %{"type" => "ephemeral"}}
      }

      message = %Message{role: :user, content: [content_with_string_key]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages

      assert encoded_message.content == [
               %{
                 type: "text",
                 text: "String key cache",
                 cache_control: %{"type" => "ephemeral"}
               }
             ]
    end

    test "ignores non-passthrough metadata keys" do
      content_with_extra_meta = %ContentPart{
        type: :text,
        text: "Has extra metadata",
        metadata: %{
          cache_control: %{type: "ephemeral"},
          custom_field: "should be ignored",
          another_field: 123
        }
      }

      message = %Message{role: :user, content: [content_with_extra_meta]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      [content_block] = encoded_message.content

      assert content_block == %{
               type: "text",
               text: "Has extra metadata",
               cache_control: %{type: "ephemeral"}
             }

      refute Map.has_key?(content_block, :custom_field)
      refute Map.has_key?(content_block, :another_field)
    end

    test "empty metadata does not add extra fields" do
      content_empty_meta = %ContentPart{type: :text, text: "No metadata", metadata: %{}}

      message = %Message{role: :user, content: [content_empty_meta]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      assert encoded_message.content == "No metadata"
    end

    test "preserves cache_control metadata in image content blocks" do
      image_data = <<0, 1, 2, 3>>

      image_with_cache =
        ContentPart.image(
          image_data,
          "image/png",
          %{cache_control: %{type: "ephemeral"}}
        )

      message = %Message{role: :user, content: [image_with_cache]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      [image_block] = encoded_message.content

      assert image_block.type == "image_url"
      assert image_block.cache_control == %{type: "ephemeral"}
      assert image_block.image_url.url =~ "data:image/png;base64,"
    end

    test "preserves cache_control metadata in image_url content blocks" do
      image_url_with_cache =
        ContentPart.image_url(
          "https://example.com/image.png",
          %{cache_control: %{type: "ephemeral"}}
        )

      message = %Message{role: :user, content: [image_url_with_cache]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      [image_block] = encoded_message.content

      assert image_block == %{
               type: "image_url",
               image_url: %{url: "https://example.com/image.png"},
               cache_control: %{type: "ephemeral"}
             }
    end

    test "mixed content with cache_control on different types" do
      text_cached = ContentPart.text("Cached text", %{cache_control: %{type: "ephemeral"}})

      image_cached =
        ContentPart.image_url("https://example.com/img.png", %{
          cache_control: %{type: "ephemeral"}
        })

      text_normal = ContentPart.text("Normal text")

      message = %Message{role: :user, content: [text_cached, image_cached, text_normal]}
      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      [text_block, image_block, normal_block] = encoded_message.content

      assert text_block.cache_control == %{type: "ephemeral"}
      assert image_block.cache_control == %{type: "ephemeral"}
      refute Map.has_key?(normal_block, :cache_control)
    end

    test "encodes tool calls correctly" do
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

      expected_message_result = %{
        messages: [
          %{
            role: "assistant",
            content: [],
            tool_calls: [
              %{
                id: "call_123",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"city":"New York"})}
              }
            ]
          }
        ]
      }

      assert Defaults.encode_context_to_openai_format(
               %Context{messages: [message_tool_calls]},
               "gpt-4"
             ) == expected_message_result
    end

    test "encodes reasoning_details for round-trip preservation" do
      reasoning_details = [
        %{"type" => "encrypted_thought", "data" => "abc123", "format" => "google-gemini-v1"}
      ]

      message = %Message{
        role: :assistant,
        content: [%ContentPart{type: :text, text: "I'll help with that."}],
        reasoning_details: reasoning_details
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gemini-2.5-flash")

      [encoded_message] = result.messages

      assert encoded_message.reasoning_details == reasoning_details
      assert encoded_message.role == "assistant"
      assert encoded_message.content == "I'll help with that."
    end

    test "does not include reasoning_details key when nil" do
      message = %Message{
        role: :assistant,
        content: [%ContentPart{type: :text, text: "Hello"}],
        reasoning_details: nil
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages

      refute Map.has_key?(encoded_message, :reasoning_details)
    end

    test "does not include reasoning_details key when empty list" do
      message = %Message{
        role: :assistant,
        content: [%ContentPart{type: :text, text: "Hello"}],
        reasoning_details: []
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages

      refute Map.has_key?(encoded_message, :reasoning_details)
    end
  end

  describe "decode_response_body_openai_format/2" do
    setup do
      %{model: %LLMDB.Model{provider: :openai, id: "gpt-4"}}
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

           assert result.usage == %{
                    input_tokens: 10,
                    output_tokens: 5,
                    total_tokens: 15,
                    reasoning_tokens: 0,
                    cached_tokens: 0
                  }

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
           assert [tool_call] = result.message.tool_calls
           assert tool_call.function.name == "get_weather"
           assert Jason.decode!(tool_call.function.arguments) == %{"city" => "New York"}
           assert tool_call.id == "call_123"
         end},

        # Missing fields handled gracefully
        {%{"choices" => [%{"message" => %{"content" => "Hello"}}]},
         fn result ->
           assert result.id == "unknown"
           assert result.model == "gpt-4"

           assert result.usage == %{
                    input_tokens: 0,
                    output_tokens: 0,
                    total_tokens: 0,
                    reasoning_tokens: 0,
                    cached_tokens: 0
                  }

           assert result.finish_reason == nil
         end}
      ]

      for {response_data, assertion_fn} <- test_cases do
        {:ok, result} = Defaults.decode_response_body_openai_format(response_data, model)
        assertion_fn.(result)
      end
    end

    test "decodes tool calls without type field (Mistral format)", %{model: model} do
      # Mistral API omits the "type" field in tool_calls, unlike OpenAI
      response_data = %{
        "id" => "chatcmpl-mistral",
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{
                  "id" => "lVauww8VE",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"city":"Paris"})
                  }
                  # Note: NO "type" => "function" field
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      {:ok, result} = Defaults.decode_response_body_openai_format(response_data, model)

      assert result.finish_reason == :tool_calls
      assert [tool_call] = result.message.tool_calls
      assert tool_call.function.name == "get_weather"
      assert Jason.decode!(tool_call.function.arguments) == %{"city" => "Paris"}
      assert tool_call.id == "lVauww8VE"
    end
  end

  describe "default_decode_stream_event/2" do
    setup do
      %{model: %LLMDB.Model{provider: :openai, id: "gpt-4"}}
    end

    test "decodes streaming events correctly", %{model: model} do
      # Content delta
      content_event = %{data: %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}}

      assert Defaults.default_decode_stream_event(content_event, model) == [
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

      [chunk] = Defaults.default_decode_stream_event(tool_event, model)
      assert chunk.type == :tool_call
      assert chunk.name == "get_weather"
      assert chunk.arguments == %{"city" => "New York"}
      assert chunk.metadata == %{id: "call_123"}
    end

    test "handles edge cases gracefully", %{model: model} do
      assert Defaults.default_decode_stream_event(%{data: %{}}, model) == []
      assert Defaults.default_decode_stream_event(%{}, model) == []
      assert Defaults.default_decode_stream_event("invalid", model) == []

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

      [chunk] = Defaults.default_decode_stream_event(invalid_json_event, model)
      assert chunk.type == :tool_call
      assert chunk.arguments == %{}
    end

    test "decodes streaming tool calls without type field (Mistral format)", %{model: model} do
      # Mistral API omits the "type" field in streaming tool_calls
      mistral_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "lVauww8VE",
                    "index" => 0,
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"city":"Paris"})
                    }
                    # Note: NO "type" => "function" field
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Defaults.default_decode_stream_event(mistral_event, model)
      assert chunk.type == :tool_call
      assert chunk.name == "get_weather"
      assert chunk.arguments == %{"city" => "Paris"}
      assert chunk.metadata == %{id: "lVauww8VE", index: 0}
    end

    test "handles nil tool names in streaming deltas", %{model: model} do
      nil_name_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_nil",
                    "type" => "function",
                    "index" => 0,
                    "function" => %{"name" => nil, "arguments" => "{}"}
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Defaults.default_decode_stream_event(nil_name_event, model)
      assert chunk.type == :meta
    end

    test "extracts reasoning_details from delta as meta chunk", %{model: model} do
      reasoning_details = [
        %{"type" => "encrypted_thought", "data" => "abc123"},
        %{"type" => "encrypted_thought", "data" => "def456"}
      ]

      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "reasoning_details" => reasoning_details
              }
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert [%StreamChunk{type: :meta, metadata: meta}] = chunks
      assert meta.reasoning_details == reasoning_details
    end

    test "emits reasoning_details alongside content chunks", %{model: model} do
      reasoning_details = [%{"type" => "thought", "signature" => "xyz789"}]

      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "content" => "Hello world",
                "reasoning_details" => reasoning_details
              }
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert length(chunks) == 2

      content_chunk = Enum.find(chunks, &(&1.type == :content))
      assert content_chunk.text == "Hello world"

      meta_chunk = Enum.find(chunks, &(&1.type == :meta))
      assert meta_chunk.metadata.reasoning_details == reasoning_details
    end

    test "does not emit reasoning_details meta when list is empty", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "content" => "Hello",
                "reasoning_details" => []
              }
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert [%StreamChunk{type: :content, text: "Hello"}] = chunks
    end

    test "does not emit reasoning_details meta when key is missing", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "content" => "Hello"
              }
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert [%StreamChunk{type: :content, text: "Hello"}] = chunks
    end

    test "reasoning_details included with finish_reason meta", %{model: model} do
      reasoning_details = [%{"type" => "thought", "data" => "final"}]

      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "reasoning_details" => reasoning_details
              },
              "finish_reason" => "stop"
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert length(chunks) == 2

      reasoning_chunk = Enum.find(chunks, &Map.has_key?(&1.metadata, :reasoning_details))
      assert reasoning_chunk.metadata.reasoning_details == reasoning_details

      finish_chunk = Enum.find(chunks, &Map.has_key?(&1.metadata, :finish_reason))
      assert finish_chunk.metadata.finish_reason == :stop
      assert finish_chunk.metadata.terminal? == true
    end
  end

  describe "ResponseBuilder reasoning_details accumulation" do
    setup do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4"}
      context = %Context{messages: []}
      %{model: model, context: context}
    end

    test "accumulates reasoning_details from meta chunks", %{model: model, context: context} do
      reasoning_details = [
        %{"type" => "encrypted_thought", "data" => "abc123"},
        %{"type" => "encrypted_thought", "data" => "def456"}
      ]

      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.meta(%{reasoning_details: reasoning_details})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.message.reasoning_details == reasoning_details
    end

    test "accumulates reasoning_details from multiple meta chunks", %{
      model: model,
      context: context
    } do
      details1 = [%{"type" => "thought", "data" => "first"}]
      details2 = [%{"type" => "thought", "data" => "second"}]

      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.meta(%{reasoning_details: details1}),
        StreamChunk.text(" world"),
        StreamChunk.meta(%{reasoning_details: details2})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.message.reasoning_details == details1 ++ details2
    end

    test "sets reasoning_details to nil when no meta chunks have reasoning_details", %{
      model: model,
      context: context
    } do
      chunks = [
        StreamChunk.text("Hello world")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.message.reasoning_details == nil
    end

    test "handles empty reasoning_details list in meta chunk", %{model: model, context: context} do
      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.meta(%{reasoning_details: []})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.message.reasoning_details == nil
    end

    test "preserves reasoning_details alongside tool calls", %{model: model, context: context} do
      reasoning_details = [%{"type" => "thought", "signature" => "xyz"}]

      chunks = [
        StreamChunk.tool_call("get_weather", %{"city" => "NYC"}, %{id: "call_123"}),
        StreamChunk.meta(%{reasoning_details: reasoning_details})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.message.reasoning_details == reasoning_details
      assert length(response.message.tool_calls) == 1
    end
  end
end
