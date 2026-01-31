defmodule ReqLLMTest do
  use ExUnit.Case, async: true

  describe "model/1 top-level API" do
    test "resolves anthropic model string spec" do
      assert {:ok, %LLMDB.Model{provider: :anthropic, id: "claude-3-5-sonnet-20240620"}} =
               ReqLLM.model("anthropic:claude-3-5-sonnet-20240620")
    end

    test "resolves anthropic model with haiku" do
      assert {:ok, %LLMDB.Model{provider: :anthropic, id: "claude-3-haiku-20240307"}} =
               ReqLLM.model("anthropic:claude-3-haiku")
    end

    test "returns error for invalid provider" do
      assert {:error, _} = ReqLLM.model("invalid_provider:some-model")
    end

    test "returns error for malformed spec" do
      assert {:error, _} = ReqLLM.model("invalid-format")
    end
  end

  describe "model/1 with map-based specs (custom providers)" do
    test "creates model from map with id and provider" do
      assert {:ok, %LLMDB.Model{provider: :custom, id: "my-model"}} =
               ReqLLM.model(%{id: "my-model", provider: :custom})
    end

    test "creates model from map with string keys" do
      assert {:ok, %LLMDB.Model{provider: :acme, id: "acme-chat"}} =
               ReqLLM.model(%{"id" => "acme-chat", "provider" => :acme})
    end

    test "passes through existing LLMDB.Model struct unchanged" do
      model = LLMDB.Model.new!(%{id: "test-model", provider: :test})
      assert {:ok, ^model} = ReqLLM.model(model)
    end

    test "returns error for map missing required fields" do
      assert {:error, _} = ReqLLM.model(%{id: "no-provider"})
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
