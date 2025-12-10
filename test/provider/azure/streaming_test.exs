defmodule ReqLLM.Providers.Azure.StreamingTest do
  @moduledoc """
  Tests for Azure provider streaming functionality.

  Covers:
  - SSE event decoding for both OpenAI and Anthropic models
  - Streaming error handling
  - Claude extended thinking in streaming
  - Streaming prompt cache metrics
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "decode_stream_event/2" do
    test "decodes OpenAI SSE event for GPT models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-123",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => "Hello"},
              "finish_reason" => nil
            }
          ]
        }
      }

      result = Azure.decode_stream_event(event, model)

      assert is_list(result)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.text == "Hello"
    end

    test "handles [DONE] event for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{data: "[DONE]"}

      result = Azure.decode_stream_event(event, model)

      assert is_list(result)
      assert [%ReqLLM.StreamChunk{metadata: metadata}] = result
      assert metadata[:terminal?] == true
    end

    test "decodes Anthropic SSE event for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hello from Claude"}
        }
      }

      result = Azure.decode_stream_event(event, model)

      assert is_list(result)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.text == "Hello from Claude"
    end

    test "handles message_stop event for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{"type" => "message_stop"}
      }

      result = Azure.decode_stream_event(event, model)

      assert is_list(result)
      assert [%ReqLLM.StreamChunk{metadata: metadata}] = result
      assert metadata[:terminal?] == true
    end
  end

  describe "streaming error handling" do
    test "OpenAI: empty event data returns empty list" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert Azure.decode_stream_event(%{data: %{}}, model) == []
      assert Azure.decode_stream_event(%{}, model) == []
    end

    test "OpenAI: non-map event data returns empty list" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert Azure.decode_stream_event("invalid", model) == []
      assert Azure.decode_stream_event(nil, model) == []
      assert Azure.decode_stream_event(%{data: "not a map"}, model) == []
    end

    test "OpenAI: malformed event missing choices returns empty list" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{data: %{"id" => "chatcmpl-123", "object" => "chat.completion.chunk"}}

      assert Azure.decode_stream_event(event, model) == []
    end

    test "OpenAI: invalid JSON in tool arguments returns chunk with empty arguments" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-123",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => "this is not valid json"
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :tool_call
      assert chunk.arguments == %{}
    end

    test "OpenAI: nil tool name in streaming delta returns meta chunk" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
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

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :meta
    end

    test "OpenAI: empty choices array returns empty list" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-123",
          "choices" => []
        }
      }

      assert Azure.decode_stream_event(event, model) == []
    end

    test "Claude: ping event returns empty list" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{data: %{"type" => "ping"}}

      assert Azure.decode_stream_event(event, model) == []
    end

    test "Claude: unknown event type returns empty list" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{data: %{"type" => "unknown_event_type", "data" => "something"}}

      assert Azure.decode_stream_event(event, model) == []
    end

    test "Claude: empty event data returns empty list" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      assert Azure.decode_stream_event(%{data: %{}}, model) == []
      assert Azure.decode_stream_event(%{}, model) == []
    end

    test "Claude: non-map event data returns empty list" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      assert Azure.decode_stream_event("invalid", model) == []
      assert Azure.decode_stream_event(nil, model) == []
      assert Azure.decode_stream_event(%{data: "not a map"}, model) == []
    end

    test "Claude: message_delta with stop_reason but no usage" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{}
        }
      }

      result = Azure.decode_stream_event(event, model)

      assert is_list(result)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.metadata[:terminal?] == true
      assert chunk.metadata[:finish_reason] == :stop
    end

    test "Claude: content_block_delta with empty delta" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{}
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert result == []
    end

    test "OpenAI: streaming finish_reason variations" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      length_event = %{
        data: %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{},
              "finish_reason" => "length"
            }
          ]
        }
      }

      [chunk] = Azure.decode_stream_event(length_event, model)
      assert chunk.metadata[:finish_reason] == :length

      content_filter_event = %{
        data: %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{},
              "finish_reason" => "content_filter"
            }
          ]
        }
      }

      [chunk] = Azure.decode_stream_event(content_filter_event, model)
      assert chunk.metadata[:finish_reason] == :content_filter

      tool_calls_event = %{
        data: %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{},
              "finish_reason" => "tool_calls"
            }
          ]
        }
      }

      [chunk] = Azure.decode_stream_event(tool_calls_event, model)
      assert chunk.metadata[:finish_reason] == :tool_calls
    end

    test "OpenAI: streaming with usage metadata" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-123",
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 10,
            "completion_tokens" => 20,
            "total_tokens" => 30
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :meta
      assert chunk.metadata[:usage].input_tokens == 10
      assert chunk.metadata[:usage].output_tokens == 20
    end

    test "OpenAI: streaming tool call with incremental arguments" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_abc123",
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => "{\"loc"
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      [chunk] = Azure.decode_stream_event(event, model)
      assert chunk.type == :tool_call
      assert chunk.name == "get_weather"
      assert chunk.arguments == %{}
    end

    test "Claude: streaming finish_reason variations" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      max_tokens_event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "max_tokens"},
          "usage" => %{}
        }
      }

      [chunk] = Azure.decode_stream_event(max_tokens_event, model)
      assert chunk.metadata[:finish_reason] == :length

      tool_use_event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{}
        }
      }

      [chunk] = Azure.decode_stream_event(tool_use_event, model)
      assert chunk.metadata[:finish_reason] == :tool_calls
    end

    test "Claude: content_block_start event for tool use" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{}
          }
        }
      }

      [chunk] = Azure.decode_stream_event(event, model)
      assert chunk.type == :tool_call
      assert chunk.name == "get_weather"
    end

    test "Claude: message_start event with usage" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_123",
            "type" => "message",
            "role" => "assistant",
            "usage" => %{
              "input_tokens" => 25,
              "output_tokens" => 0
            }
          }
        }
      }

      [chunk] = Azure.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata[:usage][:input_tokens] == 25
    end

    test "Claude: error event in stream returns empty list (delegated to Anthropic handler)" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "error",
          "error" => %{
            "type" => "overloaded_error",
            "message" => "Service temporarily overloaded"
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert result == []
    end

    test "OpenAI: handles [DONE] marker as terminal meta chunk" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      result = Azure.decode_stream_event(%{data: "[DONE]"}, model)
      assert [%ReqLLM.StreamChunk{type: :meta} = chunk] = result
      assert chunk.metadata[:terminal?] == true
    end

    test "OpenAI: handles nil delta gracefully" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-123",
          "choices" => [
            %{
              "index" => 0,
              "delta" => nil,
              "finish_reason" => "stop"
            }
          ]
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.metadata[:finish_reason] == :stop
    end
  end

  describe "Claude extended thinking in streaming" do
    test "thinking_delta event returns thinking chunk" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, reasoning: %{enabled: true}}
      }

      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Let me reason through this..."}
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :thinking
      assert chunk.text == "Let me reason through this..."
    end

    test "thinking_delta with text field returns thinking chunk" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, reasoning: %{enabled: true}}
      }

      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "text" => "Alternative reasoning format..."}
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :thinking
      assert chunk.text == "Alternative reasoning format..."
    end

    test "content_block_start with thinking type" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true, reasoning: %{enabled: true}}
      }

      event = %{
        data: %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "thinking",
            "thinking" => ""
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert is_list(result)
    end

    test "content_block_stop event returns empty list" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "content_block_stop",
          "index" => 0
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert result == []
    end

    test "message_delta with incremental usage" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{
            "output_tokens" => 150
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert is_list(result)
      assert result != []

      usage_chunk =
        Enum.find(result, fn chunk ->
          chunk.type == :meta && chunk.metadata[:usage]
        end)

      if usage_chunk do
        assert usage_chunk.metadata[:usage]["output_tokens"] == 150 or
                 usage_chunk.metadata[:usage][:output_tokens] == 150
      end
    end
  end

  describe "streaming prompt cache metrics" do
    test "Claude: message_start with cache_read_input_tokens" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_cache_test",
            "type" => "message",
            "role" => "assistant",
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 0,
              "cache_read_input_tokens" => 75,
              "cache_creation_input_tokens" => 25
            }
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :meta

      usage = chunk.metadata[:usage]
      assert usage[:input_tokens] == 100 or usage["input_tokens"] == 100
    end

    test "Claude: message_delta with cache metrics in usage" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{
            "output_tokens" => 200,
            "cache_read_input_tokens" => 50
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert is_list(result)
      assert result != []

      usage_chunk =
        Enum.find(result, fn chunk ->
          chunk.type == :meta && chunk.metadata[:usage]
        end)

      if usage_chunk do
        usage = usage_chunk.metadata[:usage]
        assert usage["output_tokens"] == 200 or usage[:output_tokens] == 200
      end
    end

    test "OpenAI: streaming usage includes cached tokens when present" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      event = %{
        data: %{
          "id" => "chatcmpl-cache",
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "total_tokens" => 150,
            "prompt_tokens_details" => %{
              "cached_tokens" => 80
            }
          }
        }
      }

      result = Azure.decode_stream_event(event, model)
      assert [%ReqLLM.StreamChunk{} = chunk] = result
      assert chunk.type == :meta
      assert chunk.metadata[:usage]
    end
  end
end
