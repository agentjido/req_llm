defmodule ReqLLM.Test.Scenarios.ObjectReasoningTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.Scenarios

  @object_reasoning [
    ReqLLM.Test.Scenarios.ObjectBasic,
    ReqLLM.Test.Scenarios.ObjectStreaming,
    ReqLLM.Test.Scenarios.Reasoning
  ]

  test "registry includes extracted object and reasoning scenarios after tool scenarios" do
    assert Enum.take(Scenarios.all(), -3) == @object_reasoning
    assert Enum.take(Scenarios.ids(), -3) == [:object_basic, :object_streaming, :reasoning]
  end

  test "object and reasoning scenarios preserve fixture names" do
    assert ReqLLM.Test.Scenarios.ObjectBasic.fixtures(:model) == ["object_basic"]
    assert ReqLLM.Test.Scenarios.ObjectStreaming.fixtures(:model) == ["object_streaming"]

    assert ReqLLM.Test.Scenarios.Reasoning.fixtures(:model) == [
             "reasoning_basic",
             "reasoning_streaming"
           ]
  end

  test "object and reasoning applicability follows model capabilities" do
    object_model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-4o-mini",
      capabilities: %{
        json: %{schema: true},
        tools: %{enabled: false},
        streaming: %{tool_calls: true},
        reasoning: %{enabled: false}
      }
    }

    reasoning_model = %LLMDB.Model{
      provider: :anthropic,
      id: "claude-haiku-4-5-20251001",
      capabilities: %{
        json: %{schema: false},
        tools: %{enabled: true},
        streaming: %{tool_calls: true},
        reasoning: %{enabled: true}
      }
    }

    plain_model = %LLMDB.Model{
      provider: :openai,
      id: "plain",
      capabilities: %{
        json: %{schema: false},
        tools: %{enabled: false},
        streaming: %{tool_calls: false},
        reasoning: %{enabled: false}
      }
    }

    assert ReqLLM.Test.Scenarios.ObjectBasic.applies?(object_model)
    assert ReqLLM.Test.Scenarios.ObjectStreaming.applies?(object_model)
    refute ReqLLM.Test.Scenarios.Reasoning.applies?(object_model)

    assert ReqLLM.Test.Scenarios.ObjectBasic.applies?(reasoning_model)
    assert ReqLLM.Test.Scenarios.ObjectStreaming.applies?(reasoning_model)
    assert ReqLLM.Test.Scenarios.Reasoning.applies?(reasoning_model)

    refute ReqLLM.Test.Scenarios.ObjectBasic.applies?(plain_model)
    refute ReqLLM.Test.Scenarios.ObjectStreaming.applies?(plain_model)
    refute ReqLLM.Test.Scenarios.Reasoning.applies?(plain_model)
  end
end
