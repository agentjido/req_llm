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
