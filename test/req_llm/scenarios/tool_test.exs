defmodule ReqLLM.Test.Scenarios.ToolTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.Scenarios

  @tool_scenarios [
    ReqLLM.Test.Scenarios.ToolMulti,
    ReqLLM.Test.Scenarios.ToolRoundTrip,
    ReqLLM.Test.Scenarios.ToolNone
  ]

  test "registry includes extracted tool scenarios after core text scenarios" do
    assert Enum.slice(Scenarios.all(), 5, 3) == @tool_scenarios
    assert Enum.slice(Scenarios.ids(), 5, 3) == [:tool_multi, :tool_round_trip, :tool_none]
  end

  test "tool scenarios preserve fixture names" do
    assert ReqLLM.Test.Scenarios.ToolMulti.fixtures(:model) == ["multi_tool"]

    assert ReqLLM.Test.Scenarios.ToolRoundTrip.fixtures(:model) == [
             "tool_round_trip_1",
             "tool_round_trip_2"
           ]

    assert ReqLLM.Test.Scenarios.ToolNone.fixtures(:model) == ["no_tool"]
  end

  test "tool scenarios only apply to tool-capable models" do
    tool_model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-4o-mini",
      capabilities: %{tools: %{enabled: true}}
    }

    plain_model = %LLMDB.Model{
      provider: :openai,
      id: "text-only",
      capabilities: %{tools: %{enabled: false}}
    }

    assert Enum.all?(@tool_scenarios, & &1.applies?(tool_model))
    refute Enum.any?(@tool_scenarios, & &1.applies?(plain_model))
  end
end
