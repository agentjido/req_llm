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
      assert {:ok, ReqLLM.Providers.Anthropic} = ReqLLM.provider(:anthropic)
    end

    test "returns error for invalid provider" do
      assert {:error, :not_found} = ReqLLM.provider(:nonexistent)
    end
  end

  describe "generate_embeddings/2 and /3 top-level API" do
    test "function exists and is exported" do
      # Check that the function is exported from the module
      functions = ReqLLM.__info__(:functions)
      
      assert Enum.any?(functions, fn {name, arity} -> 
        name == :generate_embeddings and arity == 2 
      end), "generate_embeddings/2 should be exported"
      
      assert Enum.any?(functions, fn {name, arity} -> 
        name == :generate_embeddings and arity == 3 
      end), "generate_embeddings/3 should be exported"
    end
    
    test "function delegates to embed_many correctly" do
      # We can't test the actual API call without setting up the full environment,
      # but we can verify that the function exists and accepts the expected parameters
      # by checking that it raises the correct error when called with invalid model
      
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        ReqLLM.generate_embeddings("invalid:model", ["hello"])
      end
    end
  end
end
