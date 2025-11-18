defmodule ReqLLM.Test.HelpersTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Helpers

  describe "tool_budget_for/1" do
    test "calculates correct budget from model limits (regression test for LLMDB integration)" do
      # This test would have failed with the buggy pattern match that expected
      # {:ok, {provider, id, model}} instead of {:ok, model}

      # Gemini 2.5 Pro has limits: %{output: 65536, ...}
      # Expected calculation: max(64, div(65536, 10)) = 6553
      # Buggy code would return: 150 (default fallback)
      assert tool_budget_for("google_vertex:gemini-2.5-pro") == 6553

      # Also test another model to ensure it's not hardcoded
      # Gemini 2.0 Flash has limits: %{output: 8192, ...}
      # Expected: max(64, div(8192, 10)) = 819
      assert tool_budget_for("google:gemini-2.0-flash-exp") == 819
    end

    test "returns default for models without output limits" do
      # Models without limits[:output] should fall back to cost-based or default
      # This ensures we don't break existing behavior
      result = tool_budget_for("openai:gpt-4o-mini")
      assert is_integer(result)
      assert result > 0
    end
  end

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
