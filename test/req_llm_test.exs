defmodule ReqLLMTest do
  use ExUnit.Case, async: true

  describe "model/1 top-level API" do
    test "resolves anthropic model string spec" do
      assert {:ok, %ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet-20240229"}} =
               ReqLLM.model("anthropic:claude-3-sonnet-20240229")
    end

    test "resolves anthropic model with haiku" do
      assert {:ok, %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku-20240307"}} =
               ReqLLM.model("anthropic:claude-3-haiku-20240307")
    end

    test "returns error for invalid provider" do
      assert {:error, _} = ReqLLM.model("invalid_provider:some-model")
    end

    test "returns error for malformed spec" do
      assert {:error, _} = ReqLLM.model("invalid-format")
    end
  end

  describe "provider/1 top-level API" do
    test "returns provider module for valid provider" do
      assert {:ok, ReqLLM.Providers.Groq} = ReqLLM.provider(:groq)
    end

    test "returns error for invalid provider" do
      assert {:error, %ReqLLM.Error.Invalid.Provider{provider: :nonexistent}} =
               ReqLLM.provider(:nonexistent)
    end
  end
end
