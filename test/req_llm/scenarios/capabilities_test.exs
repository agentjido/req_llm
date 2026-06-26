defmodule ReqLLM.Test.Scenarios.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.Scenarios.Capabilities

  test "capability predicates support string-keyed capability maps" do
    model = %LLMDB.Model{
      provider: :openai,
      id: "string-capabilities",
      capabilities: %{
        "json" => %{"schema" => true},
        "tools" => %{"enabled" => true, "forced_choice" => false},
        "streaming" => %{"tool_calls" => true},
        "reasoning" => %{"enabled" => true}
      }
    }

    assert Capabilities.supports_object_generation?(model)
    assert Capabilities.supports_streaming_object_generation?(model)
    assert Capabilities.supports_tool_calling?(model)
    assert Capabilities.supports_reasoning?(model)
    refute Capabilities.supports_forced_tool_choice?(model)
  end

  test "object generation can be supported through execution metadata" do
    model = %LLMDB.Model{
      provider: :openai,
      id: "execution-object",
      execution: %{"object" => %{"supported" => true}},
      capabilities: %{}
    }

    assert Capabilities.supports_object_generation?(model)
  end

  test "anthropic structured output metadata can disable tool fallback object generation" do
    model = %LLMDB.Model{
      provider: :anthropic,
      id: "anthropic-without-structured-output",
      capabilities: %{"tools" => %{"enabled" => true}},
      extra: %{
        "provider_capabilities" => %{
          "structured_outputs" => %{"supported" => false}
        }
      }
    }

    refute Capabilities.supports_object_generation?(model)
  end
end
