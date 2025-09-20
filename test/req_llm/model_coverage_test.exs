defmodule ReqLLM.ModelCoverageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Model

  describe "with_metadata/1 edge cases" do
    test "handles model not found in provider file" do
      {:error, error} = Model.with_metadata("anthropic:definitely-does-not-exist")
      assert error.class == :validation and error.tag == :model_not_found
      assert String.contains?(error.reason, "not found")
    end

    test "handles unknown provider error" do
      {:error, error} = Model.with_metadata("totally-fake-provider:model")
      assert error.tag == :invalid_provider
      assert error.reason == "Unknown provider: totally-fake-provider"
    end
  end

  describe "default_model/1 coverage" do
    test "returns default model when specified" do
      spec = %{default_model: "gpt-4", models: %{"gpt-3.5" => %{}, "gpt-4" => %{}}}
      assert Model.default_model(spec) == "gpt-4"
    end

    test "returns first model when no default specified" do
      spec = %{default_model: nil, models: %{"model-a" => %{}, "model-b" => %{}}}
      # Note: Map.keys/1 order is not guaranteed, but there should be a result
      result = Model.default_model(spec)
      assert result in ["model-a", "model-b"]
    end

    test "returns nil when no models available" do
      spec = %{default_model: nil, models: %{}}
      assert Model.default_model(spec) == nil
    end

    test "returns default even when models map is empty" do
      spec = %{default_model: "specific-model", models: %{}}
      assert Model.default_model(spec) == "specific-model"
    end
  end

  describe "new/3 with limit edge cases" do
    test "handles new/3 with limit providing default max_tokens" do
      limit = %{context: 100_000, output: 4_096}
      model = Model.new(:test, "model", limit: limit)

      # max_tokens should default to limit.output when limit is provided
      assert model.max_tokens == 4_096
      assert model.limit.output == 4_096

      # Explicit max_tokens should override
      model_override = Model.new(:test, "model", limit: limit, max_tokens: 2048)
      assert model_override.max_tokens == 2048
      # limit unchanged
      assert model_override.limit.output == 4_096
    end
  end

  describe "from/1 3-tuple edge cases" do
    test "rejects invalid types in 3-tuple" do
      # Test invalid provider in 3-tuple
      {:error, error2} = Model.from({"string_provider", "model", []})
      assert error2.class == :validation and error2.tag == :invalid_model_spec

      # Test invalid opts in 3-tuple  
      {:error, error3} = Model.from({:anthropic, "model", "invalid_opts"})
      assert error3.class == :validation and error3.tag == :invalid_model_spec
    end
  end

  describe "provider parsing edge cases" do
    test "handles provider parsing with supported but unexpected providers" do
      {:ok, model} = Model.from("anthropic:test")
      assert model.provider == :anthropic

      # Test unsupported provider that exists as atom but not in valid list
      # :string exists but not in valid providers
      {:error, error} = Model.from("string:test")
      assert error.tag == :invalid_provider
    end

    test "handles hyphenated provider names correctly" do
      # Test provider name conversion with hyphens
      {:ok, model1} = Model.from("cloudflare-workers-ai:test-model")
      assert model1.provider == :cloudflare_workers_ai

      {:ok, model2} = Model.from("google-vertex:test-model")
      assert model2.provider == :google_vertex

      {:ok, model3} = Model.from("amazon-bedrock:test-model")
      assert model3.provider == :amazon_bedrock
    end
  end

  describe "with_defaults/1 merging" do
    test "with_defaults merges existing metadata with defaults" do
      # Test merging with existing metadata
      model_with_partial =
        Model.new(:anthropic, "claude-3-sonnet",
          limit: %{context: 200_000, output: 8192},
          capabilities: %{reasoning: true}
        )

      merged = Model.with_defaults(model_with_partial)

      # Preserved
      assert merged.limit.context == 200_000
      # Preserved
      assert merged.capabilities.reasoning == true
      # Added default
      assert merged.capabilities.temperature == true
    end
  end
end
