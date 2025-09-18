defmodule ReqLLM.Response.CodecTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response.Codec
  alias ReqLLM.{Context, Message, Model, Response, StreamChunk}

  # Test helpers
  defp test_model(opts \\ []) do
    defaults = [provider: :openai, model: "gpt-4"]
    struct!(Model, Keyword.merge(defaults, opts))
  end

  defp complete_response_data(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4-turbo",
        "choices" => [
          %{
            "message" => %{"content" => "Hello, world!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 12,
          "completion_tokens" => 5,
          "total_tokens" => 17
        }
      },
      overrides
    )
  end

  describe "Response protocol implementation" do
    test "returns response as-is and empty SSE events" do
      message = %Message{
        role: :assistant,
        content: [%ContentPart{type: :text, text: "Hello"}],
        metadata: %{}
      }

      response = %Response{
        id: "test-123",
        model: "test-model",
        context: Context.new([message]),
        message: message,
        usage: %{input_tokens: 10, output_tokens: 5},
        finish_reason: :stop
      }

      model = test_model()

      assert {:ok, ^response} = Codec.decode_response(response, model)
      assert [] = Codec.decode_sse_event(response, model)
    end
  end

  describe "Map protocol - decode_response/2" do
    test "decodes complete OpenAI-compatible response" do
      model = test_model()
      data = complete_response_data()

      assert {:ok, response} = Codec.decode_response(data, model)
      assert response.id == "chatcmpl-123"
      assert response.model == "gpt-4-turbo"
      assert response.finish_reason == :stop
      assert response.usage == %{input_tokens: 12, output_tokens: 5, total_tokens: 17}
      assert response.message.role == :assistant
      assert [%ContentPart{type: :text, text: "Hello, world!"}] = response.message.content
    end

    # Table-driven tests for missing/malformed fields
    missing_field_tests = [
      {"missing id",
       %{
         "model" => "gpt-4",
         "choices" => [%{"message" => %{"content" => "Test"}, "finish_reason" => "stop"}]
       }, "unknown", "gpt-4"},
      {"missing model",
       %{
         "id" => "test-123",
         "choices" => [%{"message" => %{"content" => "Test"}, "finish_reason" => "stop"}]
       }, "test-123", "gpt-4"},
      {"missing usage",
       %{
         "id" => "test-123",
         "model" => "gpt-4",
         "choices" => [%{"message" => %{"content" => "Test"}, "finish_reason" => "stop"}]
       }, "test-123", "gpt-4"},
      {"empty choices", %{"id" => "test-123", "model" => "gpt-4", "choices" => []}, "test-123",
       "gpt-4"},
      {"missing choices", %{"id" => "test-123", "model" => "gpt-4"}, "test-123", "gpt-4"}
    ]

    for {desc, data, expected_id, expected_model} <- missing_field_tests do
      test "handles #{desc}" do
        model = test_model()
        data = unquote(Macro.escape(data))

        assert {:ok, response} = Codec.decode_response(data, model)
        assert response.id == unquote(expected_id)
        assert response.model == unquote(expected_model)

        # Missing usage should default to zeros
        if not Map.has_key?(data, "usage") do
          assert response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
        end

        # Empty/missing choices should result in nil message
        if data["choices"] in [[], nil] do
          assert response.message == nil
          assert response.finish_reason == nil
        end
      end
    end

    test "preserves provider metadata" do
      model = test_model()

      data =
        complete_response_data(%{
          "system_fingerprint" => "fp-123",
          "created" => 1_234_567_890,
          "object" => "chat.completion"
        })

      assert {:ok, response} = Codec.decode_response(data, model)

      expected_meta = %{
        "system_fingerprint" => "fp-123",
        "created" => 1_234_567_890,
        "object" => "chat.completion"
      }

      assert response.provider_meta == expected_meta
    end

    # Table-driven tests for content types
    content_type_tests = [
      {"text list content",
       [%{"type" => "text", "text" => "Hello "}, %{"type" => "text", "text" => "world!"}],
       [%ContentPart{type: :text, text: "Hello "}, %ContentPart{type: :text, text: "world!"}]},
      {"mixed valid/invalid content",
       [
         %{"type" => "text", "text" => "Valid text"},
         %{"type" => "image", "url" => "http://example.com/img.jpg"},
         %{"type" => "unknown", "data" => "something"}
       ], [%ContentPart{type: :text, text: "Valid text"}]}
    ]

    for {desc, input_content, expected_content} <- content_type_tests do
      test "handles #{desc}" do
        model = test_model()

        data =
          complete_response_data(%{
            "choices" => [
              %{
                "message" => %{"content" => unquote(Macro.escape(input_content))},
                "finish_reason" => "stop"
              }
            ]
          })

        assert {:ok, response} = Codec.decode_response(data, model)
        assert response.message.content == unquote(Macro.escape(expected_content))
      end
    end

    # Tool call tests consolidated
    test "handles tool calls variations" do
      model = test_model()

      # Valid tool call
      valid_data =
        complete_response_data(%{
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"location":"NYC"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(valid_data, model)
      assert response.finish_reason == :tool_calls

      assert [
               %ContentPart{
                 type: :tool_call,
                 tool_name: "get_weather",
                 input: %{"location" => "NYC"},
                 tool_call_id: "call-123"
               }
             ] = response.message.content

      # Invalid JSON arguments - should result in nil message
      invalid_data =
        complete_response_data(%{
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{"name" => "test_tool", "arguments" => "invalid json"}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(invalid_data, model)
      assert response.message == nil

      # Nil arguments - should use empty map
      nil_args_data =
        complete_response_data(%{
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{"name" => "test_tool", "arguments" => nil}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(nil_args_data, model)

      assert [
               %ContentPart{
                 type: :tool_call,
                 tool_name: "test_tool",
                 input: %{},
                 tool_call_id: "call-123"
               }
             ] = response.message.content

      # Malformed tool calls - should filter out invalid ones
      mixed_data =
        complete_response_data(%{
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{"name" => "valid_tool", "arguments" => ~s({"param":"value"})}
                  },
                  %{"id" => "call-456", "type" => "invalid_type"},
                  # Missing id and function
                  %{"type" => "function"}
                ]
              }
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(mixed_data, model)

      assert [
               %ContentPart{
                 type: :tool_call,
                 tool_name: "valid_tool",
                 input: %{"param" => "value"},
                 tool_call_id: "call-123"
               }
             ] = response.message.content
    end

    test "handles delta responses (streaming format)" do
      model = test_model()

      data =
        complete_response_data(%{
          "choices" => [
            %{
              "delta" => %{"content" => "Hello world"},
              "finish_reason" => "stop"
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(data, model)
      assert response.message.role == :assistant
      assert [%ContentPart{type: :text, text: "Hello world"}] = response.message.content
    end

    # Table-driven tests for finish_reason variations
    finish_reason_tests = [
      {"stop", :stop},
      {"length", :length},
      {"tool_calls", :tool_calls},
      {"content_filter", :content_filter},
      {"custom_reason", "custom_reason"},
      {nil, nil},
      {123, nil}
    ]

    for {input_reason, expected_reason} <- finish_reason_tests do
      test "handles finish_reason: #{inspect(input_reason)}" do
        model = test_model()

        data =
          complete_response_data(%{
            "choices" => [
              %{
                "message" => %{"content" => "Test"},
                "finish_reason" => unquote(Macro.escape(input_reason))
              }
            ]
          })

        assert {:ok, response} = Codec.decode_response(data, model)
        assert response.finish_reason == unquote(Macro.escape(expected_reason))
      end
    end

    test "returns error for non-map data" do
      model = test_model()

      for invalid_data <- ["invalid", 123, []] do
        assert {:error, :not_implemented} = Codec.decode_response(invalid_data, model)
      end
    end
  end

  describe "Map protocol - decode_sse_event/2" do
    test "decodes various delta formats" do
      model = test_model()

      # Content delta
      content_event = %{data: %{"choices" => [%{"delta" => %{"content" => "Hello world"}}]}}

      assert [%StreamChunk{type: :content, text: "Hello world"}] =
               Codec.decode_sse_event(content_event, model)

      # Empty/nil content should return empty list
      for empty_content <- ["", nil] do
        empty_event = %{data: %{"choices" => [%{"delta" => %{"content" => empty_content}}]}}
        assert [] = Codec.decode_sse_event(empty_event, model)
      end

      # Tool call delta
      tool_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"location":"NYC"})
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert [
               %StreamChunk{
                 type: :tool_call,
                 name: "get_weather",
                 arguments: %{"location" => "NYC"},
                 metadata: %{id: "call-123"}
               }
             ] = Codec.decode_sse_event(tool_event, model)

      # Tool call delta with invalid/nil JSON
      for invalid_args <- ["invalid json", nil] do
        invalid_event = %{
          data: %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "id" => "call-123",
                      "type" => "function",
                      "function" => %{"name" => "test_tool", "arguments" => invalid_args}
                    }
                  ]
                }
              }
            ]
          }
        }

        assert [
                 %StreamChunk{
                   type: :tool_call,
                   name: "test_tool",
                   arguments: %{},
                   metadata: %{id: "call-123"}
                 }
               ] = Codec.decode_sse_event(invalid_event, model)
      end

      # Multiple tool calls
      multi_tool_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{"name" => "tool_one", "arguments" => "{\"a\":1}"}
                  },
                  %{
                    "id" => "call-456",
                    "type" => "function",
                    "function" => %{"name" => "tool_two", "arguments" => "{\"b\":2}"}
                  }
                ]
              }
            }
          ]
        }
      }

      result = Codec.decode_sse_event(multi_tool_event, model)
      assert length(result) == 2
      assert Enum.any?(result, &(&1.name == "tool_one"))
      assert Enum.any?(result, &(&1.name == "tool_two"))

      # Malformed tool calls - should filter out invalid
      malformed_event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call-123",
                    "type" => "function",
                    "function" => %{"name" => "valid_tool", "arguments" => "{}"}
                  },
                  %{"id" => "call-456", "type" => "invalid_type"},
                  # Missing required fields
                  %{"type" => "function"}
                ]
              }
            }
          ]
        }
      }

      assert [
               %StreamChunk{
                 type: :tool_call,
                 name: "valid_tool",
                 arguments: %{},
                 metadata: %{id: "call-123"}
               }
             ] = Codec.decode_sse_event(malformed_event, model)
    end

    test "returns empty list for invalid event formats" do
      model = test_model()

      # Various invalid formats should return empty list
      invalid_events = [
        "invalid",
        %{data: "string"},
        %{data: []},
        %{other: %{}},
        # Missing choices
        %{data: %{"model" => "gpt-4"}},
        # Unknown delta format
        %{data: %{"choices" => [%{"delta" => %{"unknown_field" => "value"}}]}}
      ]

      for event <- invalid_events do
        assert [] = Codec.decode_sse_event(event, model)
      end
    end
  end

  describe "Any protocol implementation (fallback)" do
    test "handles various data types" do
      model = test_model()
      fallback_data = ["string", 123, [], {:tuple, :data}, %Date{year: 2024, month: 1, day: 1}]

      for data <- fallback_data do
        assert {:error, :not_implemented} = Codec.decode_response(data, model)
        assert [] = Codec.decode_sse_event(data, model)
      end
    end
  end

  describe "edge cases and robustness" do
    test "handles extreme and malformed data gracefully" do
      model = test_model()

      # Large content
      large_content = String.duplicate("A", 100_000)

      large_data =
        complete_response_data(%{
          "choices" => [
            %{
              "message" => %{"content" => large_content},
              "finish_reason" => "length"
            }
          ]
        })

      assert {:ok, response} = Codec.decode_response(large_data, model)
      assert response.message.content == [%ContentPart{type: :text, text: large_content}]

      # Deeply nested malformed data should not crash
      complex_malformed = %{
        "id" => "test",
        "choices" => [
          %{
            "message" => %{
              "content" => [
                %{"type" => "text", "text" => "valid text"},
                %{"type" => "text", "text" => ""},
                %{"invalid" => "structure"}
              ],
              "tool_calls" => [
                %{
                  "id" => "call-123",
                  "type" => "function",
                  "function" => %{"name" => "valid_tool", "arguments" => "{}"}
                }
              ]
            }
          }
        ],
        "usage" => "invalid_usage"
      }

      assert {:ok, response} = Codec.decode_response(complex_malformed, model)
      assert response.id == "test"
      assert response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

      # Model edge cases
      nil_model_data = %{"id" => "test", "model" => nil, "choices" => []}
      assert {:ok, response} = Codec.decode_response(nil_model_data, model)
      # Map.get with nil value doesn't use fallback
      assert response.model == nil

      nil_model_field = %{"id" => "test", "model" => "gpt-3.5-turbo", "choices" => []}
      nil_model_struct = %Model{provider: :openai, model: nil}
      assert {:ok, response} = Codec.decode_response(nil_model_field, nil_model_struct)
      assert response.model == "gpt-3.5-turbo"

      # Empty response
      assert {:ok, response} = Codec.decode_response(%{}, model)
      assert response.id == "unknown"
      assert response.model == "gpt-4"
      assert response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

      # Nil model should raise KeyError
      assert_raise(KeyError, fn -> Codec.decode_response(%{"id" => "test"}, nil) end)
    end
  end
end
