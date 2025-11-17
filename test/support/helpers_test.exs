defmodule ReqLLM.Test.HelpersTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Helpers

  describe "reasoning_overlay/3" do
    test "applies token constraints for models with reasoning capability" do
      # This test demonstrates the bug: reasoning_overlay should detect models with
      # reasoning: %{enabled: true} and apply higher token budgets, but currently fails
      # because it pattern matches on reasoning: true instead of reasoning: %{enabled: true}

      model_spec = "google_vertex:gemini-2.5-pro"
      base_opts = [max_tokens: 50, temperature: 0.0]
      min_tokens = 2000

      result = reasoning_overlay(model_spec, base_opts, min_tokens)

      # Should bump max_tokens to at least 4001 (GoogleVertex.thinking_constraints min)
      # or the specified min_tokens, whichever is higher
      assert result[:max_tokens] >= 4001,
             "Expected max_tokens to be at least 4001 for reasoning model, got #{result[:max_tokens]}"

      # Should also apply temperature constraint from thinking_constraints
      assert result[:temperature] == 1.0,
             "Expected temperature to be 1.0 for reasoning model, got #{result[:temperature]}"

      # Should include reasoning_effort
      assert result[:reasoning_effort] == :low,
             "Expected reasoning_effort to be set"
    end

    test "does not modify non-reasoning models" do
      # Non-reasoning models should pass through unchanged
      model_spec = "openai:gpt-4o-mini"
      base_opts = [max_tokens: 50, temperature: 0.5]

      result = reasoning_overlay(model_spec, base_opts)

      assert result == base_opts
    end
  end
end
