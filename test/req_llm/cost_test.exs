defmodule ReqLLM.CostTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Cost

  describe "calculate/2" do
    test "returns nil for nil cost_map" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      assert {:ok, nil} = Cost.calculate(usage, nil)
    end

    test "calculates basic cost without caching" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 1000 input at $3/M = $0.003, 500 output at $15/M = $0.0075
      assert breakdown.input_cost == 0.003
      assert breakdown.output_cost == 0.0075
      assert breakdown.total_cost == Float.round(0.003 + 0.0075, 6)
    end

    test "applies cache_read pricing for cached tokens" do
      usage = %{input: 1000, output: 500, cached_input: 800, cache_creation: 0}
      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 200 uncached at $3/M = $0.0006, 800 cached at $0.3/M = $0.00024
      expected_input = Float.round((200 * 3.0 + 800 * 0.3) / 1_000_000, 6)
      expected_output = Float.round(500 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "applies cache_write pricing for creation tokens" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 300}
      cost_map = %{input: 3.0, output: 15.0, cache_write: 3.75}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 700 regular at $3/M, 300 cache_write at $3.75/M
      expected_input = Float.round((700 * 3.0 + 300 * 3.75) / 1_000_000, 6)
      expected_output = Float.round(500 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "handles mixed cache read and write tokens" do
      usage = %{input: 1000, output: 200, cached_input: 600, cache_creation: 200}
      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 200 regular at $3/M, 600 cache_read at $0.3/M, 200 cache_write at $3.75/M
      expected_input = Float.round((200 * 3.0 + 600 * 0.3 + 200 * 3.75) / 1_000_000, 6)
      expected_output = Float.round(200 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "falls back to input rate when cache rates not specified" do
      usage = %{input: 1000, output: 500, cached_input: 400, cache_creation: 200}
      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # All tokens at input rate since no cache rates specified
      expected_input = Float.round(1000 * 3.0 / 1_000_000, 6)
      expected_output = Float.round(500 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "clamps cached tokens to not exceed input tokens" do
      usage = %{input: 500, output: 200, cached_input: 800, cache_creation: 0}
      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # cached_input clamped to 500 (all at cache rate, 0 regular)
      expected_input = Float.round(500 * 0.3 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
    end

    test "handles string keys in cost_map" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      cost_map = %{"input" => 3.0, "output" => 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      assert breakdown.input_cost == 0.003
      assert breakdown.output_cost == 0.0075
    end

    test "returns nil when input_rate is missing" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      cost_map = %{output: 15.0}

      assert {:ok, nil} = Cost.calculate(usage, cost_map)
    end

    test "returns nil when output_rate is missing" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      cost_map = %{input: 3.0}

      assert {:ok, nil} = Cost.calculate(usage, cost_map)
    end
  end

  describe "calculate/2 with Anthropic semantics (input excludes cached)" do
    test "handles cached tokens correctly when input excludes cached" do
      # Anthropic: input (500) is NEW tokens only, cached (800) is separate
      # Total conceptual = 500 + 800 = 1300
      usage = %{
        input: 500,
        output: 200,
        cached_input: 800,
        cache_creation: 0,
        input_includes_cached: false
      }

      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 500 regular at $3/M, 800 cached at $0.3/M
      expected_input = Float.round((500 * 3.0 + 800 * 0.3) / 1_000_000, 6)
      expected_output = Float.round(200 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "handles real Anthropic usage pattern" do
      # Real example: input_tokens: 12 (new only), cache_read_input_tokens: 5484
      usage = %{
        input: 12,
        output: 200,
        cached_input: 5484,
        cache_creation: 0,
        input_includes_cached: false
      }

      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 12 regular at $3/M, 5484 cached at $0.3/M
      expected_input = Float.round((12 * 3.0 + 5484 * 0.3) / 1_000_000, 6)
      expected_output = Float.round(200 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "handles cache creation tokens" do
      # Anthropic: input (100) + cache_read (800) + cache_creation (200) = 1100 total
      usage = %{
        input: 100,
        output: 200,
        cached_input: 800,
        cache_creation: 200,
        input_includes_cached: false
      }

      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 100 regular at $3/M, 800 cached at $0.3/M, 200 creation at $3.75/M
      expected_input = Float.round((100 * 3.0 + 800 * 0.3 + 200 * 3.75) / 1_000_000, 6)
      expected_output = Float.round(200 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end
  end

  describe "calculate/2 with Google Gemini thinking tokens" do
    test "adds thinking tokens to output cost when add_reasoning_to_cost is true" do
      # Google Gemini: candidatesTokenCount (500) + thoughtsTokenCount (200) are SEPARATE
      usage = %{
        input: 1000,
        output: 500,
        reasoning: 200,
        cached_input: 0,
        cache_creation: 0,
        add_reasoning_to_cost: true
      }

      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 1000 input at $3/M = $0.003
      # 500 output + 200 reasoning = 700 at $15/M = $0.0105
      expected_input = Float.round(1000 * 3.0 / 1_000_000, 6)
      expected_output = Float.round((500 + 200) * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
      assert breakdown.total_cost == Float.round(expected_input + expected_output, 6)
    end

    test "handles real Gemini 2.5 thinking usage pattern" do
      # Real example: prompt: 1000, candidates: 500, thoughts: 618
      usage = %{
        input: 1000,
        output: 500,
        reasoning: 618,
        cached_input: 0,
        cache_creation: 0,
        add_reasoning_to_cost: true
      }

      # Gemini 2.5 Flash pricing: $0.30/M input, $2.50/M output
      cost_map = %{input: 0.30, output: 2.50}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 1000 input at $0.30/M = $0.0003
      # 500 output + 618 reasoning = 1118 at $2.50/M = $0.002795
      expected_input = Float.round(1000 * 0.30 / 1_000_000, 6)
      expected_output = Float.round((500 + 618) * 2.50 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "works with thinking tokens and caching combined" do
      usage = %{
        input: 1000,
        output: 200,
        reasoning: 100,
        cached_input: 300,
        cache_creation: 0,
        add_reasoning_to_cost: true
      }

      cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # 700 regular at $3/M, 300 cached at $0.3/M
      # 200 output + 100 reasoning = 300 at $15/M
      expected_input = Float.round((700 * 3.0 + 300 * 0.3) / 1_000_000, 6)
      expected_output = Float.round((200 + 100) * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end
  end

  describe "calculate/2 default behavior (status quo for non-Gemini providers)" do
    test "does not add reasoning tokens by default" do
      # Default behavior: reasoning tokens are tracked but NOT added to cost.
      # This maintains status quo for providers like OpenAI where completion_tokens
      # already includes reasoning.
      usage = %{
        input: 1000,
        output: 700,
        reasoning: 200,
        cached_input: 0,
        cache_creation: 0
        # Note: add_reasoning_to_cost NOT set (defaults to false)
      }

      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      # Reasoning NOT added - only output tokens charged
      expected_input = Float.round(1000 * 3.0 / 1_000_000, 6)
      expected_output = Float.round(700 * 15.0 / 1_000_000, 6)

      assert breakdown.input_cost == expected_input
      assert breakdown.output_cost == expected_output
    end

    test "handles zero reasoning tokens" do
      usage = %{
        input: 1000,
        output: 500,
        reasoning: 0,
        cached_input: 0,
        cache_creation: 0
      }

      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      assert breakdown.input_cost == 0.003
      assert breakdown.output_cost == 0.0075
    end

    test "handles missing reasoning key" do
      usage = %{
        input: 1000,
        output: 500,
        cached_input: 0,
        cache_creation: 0
      }

      cost_map = %{input: 3.0, output: 15.0}

      {:ok, breakdown} = Cost.calculate(usage, cost_map)

      assert breakdown.input_cost == 0.003
      assert breakdown.output_cost == 0.0075
    end
  end

  describe "add_cost_to_usage/2" do
    test "adds cost fields to usage map" do
      usage = %{input: 1000, output: 500, cached_input: 0, cache_creation: 0}
      cost_map = %{input: 3.0, output: 15.0}

      result = Cost.add_cost_to_usage(usage, cost_map)

      assert result.input_cost == 0.003
      assert result.output_cost == 0.0075
      assert result.total_cost == Float.round(0.003 + 0.0075, 6)
      # Original fields preserved
      assert result.input == 1000
      assert result.output == 500
    end

    test "returns usage unchanged for nil cost_map" do
      usage = %{input: 1000, output: 500}
      assert Cost.add_cost_to_usage(usage, nil) == usage
    end

    test "returns usage unchanged when cost cannot be calculated" do
      usage = %{input: 1000, output: 500}
      # missing output rate
      cost_map = %{input: 3.0}

      assert Cost.add_cost_to_usage(usage, cost_map) == usage
    end
  end
end
