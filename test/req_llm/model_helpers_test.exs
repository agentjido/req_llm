defmodule ReqLLM.ModelHelpersTest do
  use ExUnit.Case, async: true

  alias ReqLLM.ModelHelpers

  # Helper to create test model with capabilities
  defp test_model(capabilities) do
    %LLMDB.Model{
      id: "test-model",
      provider: :test,
      capabilities: capabilities
    }
  end

  describe "reasoning_enabled?/1" do
    test "returns true when model has reasoning.enabled = true" do
      model = test_model(%{reasoning: %{enabled: true}})
      assert ModelHelpers.reasoning_enabled?(model)
    end

    test "returns false when reasoning.enabled is false" do
      model = test_model(%{reasoning: %{enabled: false}})
      refute ModelHelpers.reasoning_enabled?(model)
    end

    test "returns false when reasoning.enabled is nil" do
      model = test_model(%{reasoning: %{enabled: nil}})
      refute ModelHelpers.reasoning_enabled?(model)
    end

    test "returns false when reasoning is missing" do
      model = test_model(%{})
      refute ModelHelpers.reasoning_enabled?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.reasoning_enabled?(%{})
      refute ModelHelpers.reasoning_enabled?(nil)
    end
  end

  describe "json_native?/1" do
    test "returns true when model has json.native = true" do
      model = test_model(%{json: %{native: true}})
      assert ModelHelpers.json_native?(model)
    end

    test "returns false when json.native is false" do
      model = test_model(%{json: %{native: false}})
      refute ModelHelpers.json_native?(model)
    end

    test "returns false when json is missing" do
      model = test_model(%{})
      refute ModelHelpers.json_native?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.json_native?(%{})
    end
  end

  describe "json_schema?/1" do
    test "returns true when model has json.schema = true" do
      model = test_model(%{json: %{schema: true}})
      assert ModelHelpers.json_schema?(model)
    end

    test "returns false when json.schema is false" do
      model = test_model(%{json: %{schema: false}})
      refute ModelHelpers.json_schema?(model)
    end

    test "returns false when json is missing" do
      model = test_model(%{})
      refute ModelHelpers.json_schema?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.json_schema?(%{})
    end
  end

  describe "json_strict?/1" do
    test "returns true when model has json.strict = true" do
      model = test_model(%{json: %{strict: true}})
      assert ModelHelpers.json_strict?(model)
    end

    test "returns false when json.strict is false" do
      model = test_model(%{json: %{strict: false}})
      refute ModelHelpers.json_strict?(model)
    end

    test "returns false when json is missing" do
      model = test_model(%{})
      refute ModelHelpers.json_strict?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.json_strict?(%{})
    end
  end

  describe "tools_enabled?/1" do
    test "returns true when model has tools.enabled = true" do
      model = test_model(%{tools: %{enabled: true}})
      assert ModelHelpers.tools_enabled?(model)
    end

    test "returns false when tools.enabled is false" do
      model = test_model(%{tools: %{enabled: false}})
      refute ModelHelpers.tools_enabled?(model)
    end

    test "returns false when tools is missing" do
      model = test_model(%{})
      refute ModelHelpers.tools_enabled?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.tools_enabled?(%{})
    end
  end

  describe "tools_strict?/1" do
    test "returns true when model has tools.strict = true" do
      model = test_model(%{tools: %{strict: true}})
      assert ModelHelpers.tools_strict?(model)
    end

    test "returns false when tools.strict is false" do
      model = test_model(%{tools: %{strict: false}})
      refute ModelHelpers.tools_strict?(model)
    end

    test "returns false when tools is missing" do
      model = test_model(%{})
      refute ModelHelpers.tools_strict?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.tools_strict?(%{})
    end
  end

  describe "tools_parallel?/1" do
    test "returns true when model has tools.parallel = true" do
      model = test_model(%{tools: %{parallel: true}})
      assert ModelHelpers.tools_parallel?(model)
    end

    test "returns false when tools.parallel is false" do
      model = test_model(%{tools: %{parallel: false}})
      refute ModelHelpers.tools_parallel?(model)
    end

    test "returns false when tools is missing" do
      model = test_model(%{})
      refute ModelHelpers.tools_parallel?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.tools_parallel?(%{})
    end
  end

  describe "tools_streaming?/1" do
    test "returns true when model has tools.streaming = true" do
      model = test_model(%{tools: %{streaming: true}})
      assert ModelHelpers.tools_streaming?(model)
    end

    test "returns false when tools.streaming is false" do
      model = test_model(%{tools: %{streaming: false}})
      refute ModelHelpers.tools_streaming?(model)
    end

    test "returns false when tools is missing" do
      model = test_model(%{})
      refute ModelHelpers.tools_streaming?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.tools_streaming?(%{})
    end
  end

  describe "streaming_text?/1" do
    test "returns true when model has streaming.text = true" do
      model = test_model(%{streaming: %{text: true}})
      assert ModelHelpers.streaming_text?(model)
    end

    test "returns false when streaming.text is false" do
      model = test_model(%{streaming: %{text: false}})
      refute ModelHelpers.streaming_text?(model)
    end

    test "returns false when streaming is missing" do
      model = test_model(%{})
      refute ModelHelpers.streaming_text?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.streaming_text?(%{})
    end
  end

  describe "streaming_tool_calls?/1" do
    test "returns true when model has streaming.tool_calls = true" do
      model = test_model(%{streaming: %{tool_calls: true}})
      assert ModelHelpers.streaming_tool_calls?(model)
    end

    test "returns false when streaming.tool_calls is false" do
      model = test_model(%{streaming: %{tool_calls: false}})
      refute ModelHelpers.streaming_tool_calls?(model)
    end

    test "returns false when streaming is missing" do
      model = test_model(%{})
      refute ModelHelpers.streaming_tool_calls?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.streaming_tool_calls?(%{})
    end
  end

  describe "chat?/1" do
    test "returns true when model has chat = true" do
      model = test_model(%{chat: true})
      assert ModelHelpers.chat?(model)
    end

    test "returns false when chat is false" do
      model = test_model(%{chat: false})
      refute ModelHelpers.chat?(model)
    end

    test "returns false when chat is nil" do
      model = test_model(%{chat: nil})
      refute ModelHelpers.chat?(model)
    end

    test "returns false when chat is missing" do
      model = test_model(%{})
      refute ModelHelpers.chat?(model)
    end

    test "returns false for non-Model structs" do
      refute ModelHelpers.chat?(%{})
    end
  end

  describe "list_helpers/0" do
    test "returns sorted list of all helper function names" do
      helpers = ModelHelpers.list_helpers()

      assert is_list(helpers)
      assert length(helpers) == 11

      assert :reasoning_enabled? in helpers
      assert :json_native? in helpers
      assert :json_schema? in helpers
      assert :json_strict? in helpers
      assert :tools_enabled? in helpers
      assert :tools_strict? in helpers
      assert :tools_parallel? in helpers
      assert :tools_streaming? in helpers
      assert :streaming_text? in helpers
      assert :streaming_tool_calls? in helpers
      assert :chat? in helpers

      # Verify it's sorted
      assert helpers == Enum.sort(helpers)
    end
  end

  describe "adaptive_thinking_required?/1" do
    test "returns true for string-keyed adaptive-only thinking metadata" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7",
        provider: :anthropic,
        extra: %{
          "capabilities" => %{
            "thinking" => %{
              "types" => %{
                "adaptive" => %{"supported" => true},
                "enabled" => %{"supported" => false}
              }
            }
          }
        }
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns true for atom-keyed adaptive-only thinking metadata" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7",
        provider: :anthropic,
        extra: %{
          capabilities: %{
            thinking: %{
              types: %{
                adaptive: %{supported: true},
                enabled: %{supported: false}
              }
            }
          }
        }
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns true for normalized adaptive-only thinking capabilities" do
      model = %LLMDB.Model{
        id: "claude-opus-4-8",
        provider: :anthropic,
        capabilities: %{
          reasoning: %{
            thinking: %{
              types: ["adaptive"]
            }
          }
        }
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns true for provider adaptive-only thinking metadata" do
      model = %LLMDB.Model{
        id: "claude-opus-4-8",
        provider: :anthropic,
        extra: %{
          provider_capabilities: %{
            thinking: %{
              types: %{
                adaptive: %{supported: true},
                enabled: %{supported: false}
              }
            }
          }
        }
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns false when both supported or neither" do
      model_both = %LLMDB.Model{
        id: "test",
        provider: :anthropic,
        extra: %{
          "capabilities" => %{
            "thinking" => %{
              "types" => %{
                "adaptive" => %{"supported" => true},
                "enabled" => %{"supported" => true}
              }
            }
          }
        }
      }

      refute ModelHelpers.adaptive_thinking_required?(model_both)

      model_none = %LLMDB.Model{id: "test", provider: :anthropic, extra: %{}}
      refute ModelHelpers.adaptive_thinking_required?(model_none)
    end

    test "returns false when adaptive supported but enabled omitted (sparse metadata, not explicit false)" do
      model = %LLMDB.Model{
        id: "test",
        provider: :anthropic,
        extra: %{
          "capabilities" => %{
            "thinking" => %{
              "types" => %{
                "adaptive" => %{"supported" => true}
              }
            }
          }
        }
      }

      refute ModelHelpers.adaptive_thinking_required?(model)
    end

    test "derives sparse Bedrock Claude metadata from the native Anthropic catalog" do
      model = %LLMDB.Model{
        id: "anthropic.claude-opus-4-7-v1:0",
        provider: :amazon_bedrock,
        provider_model_id: "us.anthropic.claude-opus-4-7-v1:0",
        capabilities: %{reasoning: %{enabled: true}},
        extra: %{family: "claude-opus"}
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "derives sparse Vertex Claude metadata from the native Anthropic catalog" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7@20260414",
        provider: :google_vertex_anthropic,
        capabilities: %{reasoning: %{enabled: true}},
        extra: %{family: "claude-opus"}
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "derives sparse Azure Claude metadata from the native Anthropic catalog" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}},
        extra: %{family: "claude-opus"}
      }

      assert ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns false for hosted Claude models whose native catalog metadata supports enabled thinking" do
      model = %LLMDB.Model{
        id: "anthropic.claude-opus-4-1-20250805-v1:0",
        provider: :amazon_bedrock,
        provider_model_id: "us.anthropic.claude-opus-4-1-20250805-v1:0",
        capabilities: %{reasoning: %{enabled: true}},
        extra: %{family: "claude-opus"}
      }

      refute ModelHelpers.adaptive_thinking_required?(model)
    end

    test "returns false for non-Model" do
      refute ModelHelpers.adaptive_thinking_required?(%{})
    end
  end

  describe "anthropic_thinking_types/1 and anthropic_thinking_off_type/1" do
    test "reads list and map thinking type metadata" do
      list_model = %LLMDB.Model{
        provider: :anthropic,
        id: "claude-example",
        capabilities: %{reasoning: %{thinking: %{types: ["adaptive", "between_tools"]}}}
      }

      map_model = %LLMDB.Model{
        provider: :anthropic,
        id: "claude-example",
        extra: %{
          capabilities: %{
            thinking: %{
              types: %{adaptive: %{supported: true}, disabled: %{supported: true}, enabled: false}
            }
          }
        }
      }

      assert ModelHelpers.anthropic_thinking_types(list_model) == ["adaptive", "between_tools"]
      assert ModelHelpers.anthropic_thinking_types(map_model) == ["adaptive", "disabled"]
      assert ModelHelpers.anthropic_thinking_off_type(list_model) == "between_tools"
      assert ModelHelpers.anthropic_thinking_off_type(map_model) == "disabled"
    end

    test "falls back to the native Anthropic catalog for sparse hosted Claude models" do
      cases = [
        {:amazon_bedrock, "anthropic.claude-sonnet-5-5", "global.anthropic.claude-sonnet-5-5",
         "between_tools"},
        {:amazon_bedrock, "anthropic.claude-opus-5", "in.anthropic.claude-opus-5", "disabled"},
        {:google_vertex_anthropic, "claude-opus-5-5@default", nil, nil},
        {:azure, "claude-haiku-5-5", nil, "disabled"}
      ]

      for {provider, id, provider_model_id, off_type} <- cases do
        model = %LLMDB.Model{
          id: id,
          provider: provider,
          provider_model_id: provider_model_id,
          capabilities: %{reasoning: %{enabled: true}}
        }

        assert ModelHelpers.anthropic_thinking_types(model) != [], id
        assert ModelHelpers.anthropic_thinking_off_type(model) == off_type, id
      end
    end

    test "returns no types and no off type when metadata is unavailable" do
      model = %LLMDB.Model{
        provider: :anthropic,
        id: "claude-unknown",
        capabilities: %{reasoning: %{enabled: true}}
      }

      assert ModelHelpers.anthropic_thinking_types(model) == []
      assert ModelHelpers.anthropic_thinking_off_type(model) == nil
      assert ModelHelpers.anthropic_thinking_types(%{}) == []
    end

    test "anthropic_thinking_off?/1 recognizes disabled and between_tools in either key style" do
      assert ModelHelpers.anthropic_thinking_off?(%{type: "disabled"})
      assert ModelHelpers.anthropic_thinking_off?(%{"type" => "between_tools"})
      refute ModelHelpers.anthropic_thinking_off?(%{type: "adaptive"})
      refute ModelHelpers.anthropic_thinking_off?(%{"type" => "enabled", "budget_tokens" => 1024})
      refute ModelHelpers.anthropic_thinking_off?(nil)
    end
  end
end
