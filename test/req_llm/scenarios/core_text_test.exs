defmodule ReqLLM.Test.Scenarios.CoreTextTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.Scenarios

  @core [
    ReqLLM.Test.Scenarios.Basic,
    ReqLLM.Test.Scenarios.Streaming,
    ReqLLM.Test.Scenarios.TokenLimit,
    ReqLLM.Test.Scenarios.Usage,
    ReqLLM.Test.Scenarios.ContextAppend
  ]

  test "registry includes extracted core text scenarios in stable order" do
    assert Enum.take(Scenarios.all(), 5) == @core

    assert Enum.take(Scenarios.ids(), 5) == [
             :basic,
             :streaming,
             :token_limit,
             :usage,
             :context_append
           ]
  end

  test "core text scenarios preserve fixture names" do
    assert ReqLLM.Test.Scenarios.Basic.fixtures(:model) == ["basic"]
    assert ReqLLM.Test.Scenarios.Streaming.fixtures(:model) == ["streaming"]
    assert ReqLLM.Test.Scenarios.TokenLimit.fixtures(:model) == ["token_limit"]
    assert ReqLLM.Test.Scenarios.Usage.fixtures(:model) == ["usage"]

    assert ReqLLM.Test.Scenarios.ContextAppend.fixtures(:model) == [
             "context_append_1",
             "context_append_2"
           ]
  end

  test "core text scenarios apply to every selected text model" do
    model = %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"}

    assert Scenarios.for_model(model) == @core
  end
end
