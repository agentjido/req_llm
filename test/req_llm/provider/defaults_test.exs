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

    test "raises for unsupported video_url content parts" do
      video_url_part = ContentPart.video_url("https://example.com/clip.mp4")

      message = %Message{role: :user, content: [video_url_part]}
      context = %Context{messages: [message]}

      assert_raise ReqLLM.Error.Invalid.Message,
                   ~r/Video URLs are not supported for this provider/,
                   fn ->
                     Defaults.encode_context_to_openai_format(context, "gpt-4")
                   end
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
            content: "",
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

    test "strips :thinking content parts from encoding and emits reasoning_content for assistant" do
      message = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "Let me reason about this..."},
          %ContentPart{type: :text, text: "Here is the answer."}
        ]
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      # :thinking part stripped, single text part flattened to string
      assert encoded_message.content == "Here is the answer."
      assert encoded_message.reasoning_content == "Let me reason about this..."
    end

    test "joins multiple thinking parts into single reasoning_content" do
      message = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "Step 1: analyze"},
          %ContentPart{type: :thinking, text: "Step 2: conclude"},
          %ContentPart{type: :text, text: "Final answer."}
        ]
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      assert encoded_message.content == "Final answer."
      assert encoded_message.reasoning_content == "Step 1: analyzeStep 2: conclude"
    end

    test "does not emit reasoning_content for non-assistant roles" do
      message = %Message{
        role: :user,
        content: [
          %ContentPart{type: :thinking, text: "User-provided thought"},
          %ContentPart{type: :text, text: "Hello"}
        ]
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      assert encoded_message.content == "Hello"
      refute Map.has_key?(encoded_message, :reasoning_content)
    end

    test "preserves tool_calls alongside reasoning_content for assistant" do
      message = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "Internal chain-of-thought"}
        ],
        tool_calls: [
          %{
            id: "call_abc",
            type: "function",
            function: %{name: "get_weather", arguments: ~s({"city":"NYC"})}
          }
        ]
      }

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      # All parts filtered → empty array collapsed to ""
      assert encoded_message.content == ""
      # Tool calls still present
      assert length(encoded_message.tool_calls) == 1
      # reasoning_content emitted for assistant
      assert encoded_message.reasoning_content == "Internal chain-of-thought"
    end

    test "collapses empty content list to empty string" do
      message = %Message{role: :assistant, content: []}

      context = %Context{messages: [message]}
      result = Defaults.encode_context_to_openai_format(context, "gpt-4")

      [encoded_message] = result.messages
      assert encoded_message.content == ""
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
      assert chunk.metadata.invalid_arguments
    end

    test "normalizes non-object tool arguments in streaming deltas", %{model: model} do
      scalar_args_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_scalar",
                    "type" => "function",
                    "function" => %{"name" => "get_weather", "arguments" => ~s("Paris")}
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Defaults.default_decode_stream_event(scalar_args_event, model)
      assert chunk.type == :tool_call
      assert chunk.arguments == %{}
      assert chunk.metadata.id == "call_scalar"
      assert chunk.metadata.invalid_arguments
      assert chunk.metadata.raw_arguments == ~s("Paris")
      assert chunk.metadata.decoded_arguments == "Paris"
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

    test "emits terminal error chunk for SSE error event with nested message", %{model: model} do
      # OpenAI-compatible providers (LMStudio, OpenRouter on overflow, Ollama, vLLM)
      # return errors mid-stream as `data: {"error": {"message": "..."}}`. Without
      # an explicit clause these were silently dropped, leaving downstream code
      # with a finish_reason of `:incomplete` and no diagnostic.
      error_event = %{
        data: %{
          "error" => %{
            "message" =>
              "The number of tokens to keep from the initial prompt is greater than the context length (n_keep: 6141 >= n_ctx: 4096)"
          }
        }
      }

      assert [chunk] = Defaults.default_decode_stream_event(error_event, model)
      assert chunk.type == :meta
      assert chunk.metadata.finish_reason == :error
      assert chunk.metadata.terminal? == true

      assert chunk.metadata.error =~
               "The number of tokens to keep from the initial prompt is greater than the context length"
    end

    test "emits terminal error chunk for SSE error event with bare string", %{model: model} do
      # Some OpenAI-compatible providers send `data: {"error": "message"}` directly
      # without the nested `message` key. Tolerate that variant too.
      error_event = %{data: %{"error" => "rate limit exceeded"}}

      assert [chunk] = Defaults.default_decode_stream_event(error_event, model)
      assert chunk.type == :meta
      assert chunk.metadata.finish_reason == :error
      assert chunk.metadata.error == "rate limit exceeded"
      assert chunk.metadata.terminal? == true
    end

    test "error event takes precedence over choices in same payload", %{model: model} do
      # Defensive: even if a malformed payload contains both `error` and `choices`,
      # the error must win because `error` is terminal by definition.
      mixed_event = %{
        data: %{
          "error" => %{"message" => "boom"},
          "choices" => [%{"delta" => %{"content" => "ignored"}}]
        }
      }

      assert [chunk] = Defaults.default_decode_stream_event(mixed_event, model)
      assert chunk.type == :meta
      assert chunk.metadata.finish_reason == :error
      assert chunk.metadata.error == "boom"
    end

    test "does not match error event when message is non-string and no fallback hits",
         %{model: model} do
      # Guard regression: the new clause must require `message` to be a binary.
      # A non-string `message` (rare but possible from malformed providers) should
      # fall through to the regular `is_map(data)` clause, which returns [].
      weird_event = %{data: %{"error" => %{"message" => %{"nested" => "thing"}}}}

      assert Defaults.default_decode_stream_event(weird_event, model) == []
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

  describe "ResponseBuilder logprobs accumulation" do
    setup do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4"}
      context = %Context{messages: []}
      %{model: model, context: context}
    end

    test "sets provider_meta logprobs from meta chunks", %{model: model, context: context} do
      tokens = [
        %{"token" => "Hello", "logprob" => -0.5, "bytes" => [72, 101, 108, 108, 111]},
        %{"token" => " world", "logprob" => -0.3, "bytes" => [32, 119, 111, 114, 108, 100]}
      ]

      chunks = [
        StreamChunk.text("Hello world"),
        StreamChunk.meta(%{logprobs: tokens})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.provider_meta[:logprobs] == tokens
    end

    test "accumulates logprobs across multiple meta chunks", %{model: model, context: context} do
      tokens1 = [%{"token" => "Hello", "logprob" => -0.5}]
      tokens2 = [%{"token" => " world", "logprob" => -0.3}]

      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.meta(%{logprobs: tokens1}),
        StreamChunk.text(" world"),
        StreamChunk.meta(%{logprobs: tokens2})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert response.provider_meta[:logprobs] == tokens1 ++ tokens2
    end

    test "omits logprobs key from provider_meta when no logprobs chunks", %{
      model: model,
      context: context
    } do
      chunks = [StreamChunk.text("Hello world")]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      refute Map.has_key?(response.provider_meta, :logprobs)
    end

    test "merges logprobs into existing provider_meta", %{model: model, context: context} do
      tokens = [%{"token" => "Hi", "logprob" => -0.1}]

      chunks = [
        StreamChunk.text("Hi"),
        StreamChunk.meta(%{logprobs: tokens})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{provider_meta: %{model_version: "gpt-4-0125"}},
          model: model,
          context: context
        )

      assert response.provider_meta[:logprobs] == tokens
      assert response.provider_meta[:model_version] == "gpt-4-0125"
    end
  end

  describe "default_decode_stream_event/2 logprobs" do
    setup do
      %{model: %LLMDB.Model{provider: :openai, id: "gpt-4"}}
    end

    test "emits meta chunk with logprobs when choice has logprobs content", %{model: model} do
      tokens = [
        %{"token" => "Hello", "logprob" => -0.5, "bytes" => [72]},
        %{"token" => " world", "logprob" => -0.3, "bytes" => [32]}
      ]

      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{"content" => "Hello world"},
              "logprobs" => %{"content" => tokens}
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      content_chunk = Enum.find(chunks, &(&1.type == :content))
      assert content_chunk.text == "Hello world"

      logprobs_chunk =
        Enum.find(chunks, fn c -> c.type == :meta and Map.has_key?(c.metadata, :logprobs) end)

      assert logprobs_chunk != nil
      assert logprobs_chunk.metadata.logprobs == tokens
    end

    test "does not emit logprobs meta chunk when logprobs is nil", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{"content" => "Hello"},
              "logprobs" => nil
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert Enum.any?(chunks, &(&1.type == :content))

      refute Enum.any?(chunks, fn c -> c.type == :meta and Map.has_key?(c.metadata, :logprobs) end)
    end

    test "does not emit logprobs meta chunk when logprobs key is absent", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{"delta" => %{"content" => "Hello"}}
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      assert [%StreamChunk{type: :content, text: "Hello"}] = chunks
    end

    test "does not emit logprobs meta chunk when logprobs content is empty list", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{"content" => "Hello"},
              "logprobs" => %{"content" => []}
            }
          ]
        }
      }

      chunks = Defaults.default_decode_stream_event(event, model)

      refute Enum.any?(chunks, fn c -> c.type == :meta and Map.has_key?(c.metadata, :logprobs) end)
    end
  end

  describe "default_decode_response/1" do
    test "handles unknown provider prefix in model string without atomizing" do
      req =
        Req.new()
        |> Map.update!(:options, fn opts ->
          Map.merge(opts, %{
            operation: :chat,
            model: "unknown_provider:model-1",
            context: %Context{messages: []}
          })
        end)

      resp = %Req.Response{
        status: 200,
        body: %{
          "id" => "chatcmpl-unknown",
          "model" => "unknown_provider:model-1",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Hello"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        }
      }

      {returned_req, returned_resp} = Defaults.default_decode_response({req, resp})

      assert returned_req == req
      assert %ReqLLM.Response{} = returned_resp.body
      assert returned_resp.body.model == "unknown_provider:model-1"
      assert returned_resp.body.finish_reason == :stop
    end

    test "normalizes non-object tool arguments in non-streaming responses" do
      req =
        Req.new()
        |> Map.update!(:options, fn opts ->
          Map.merge(opts, %{
            operation: :chat,
            model: "groq:llama-3.1-8b-instant",
            context: %Context{messages: []}
          })
        end)

      resp = %Req.Response{
        status: 200,
        body: %{
          "id" => "chatcmpl-tool-scalar",
          "model" => "groq:llama-3.1-8b-instant",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_scalar",
                    "type" => "function",
                    "function" => %{
                      "name" => "agent.build_workflow",
                      "arguments" => ~s("draft")
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        }
      }

      {_returned_req, returned_resp} = Defaults.default_decode_response({req, resp})
      [tool_call] = returned_resp.body.message.tool_calls

      assert Jason.decode!(tool_call.function.arguments) == %{}
      assert returned_resp.body.finish_reason == :tool_calls
      assert returned_resp.body.message.metadata == %{}
    end
  end
end
