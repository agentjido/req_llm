defmodule ReqLLM.AnthropicCatalogBillingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Usage
  alias ReqLLM.Usage.Cost

  @context %{api: "chat", inference_geo: "global"}

  test "released Haiku 5.5 prices both cache write durations independently" do
    model = ReqLLM.model!("anthropic:claude-haiku-5-5")
    usage = mixed_usage(14)
    priced = Cost.apply(usage, model, pricing_context: @context)

    assert priced.cache_write_tokens_by_ttl == %{"5m" => 33_031, "1h" => 33_034}
    assert priced.pricing.status == :priced
    assert_in_delta priced.total_cost, 0.010739, 1.0e-12

    writes = Enum.filter(priced.cost.line_items, &String.starts_with?(&1.id, "token.cache_write"))
    assert Enum.sort(Enum.map(writes, &{&1.count, &1.rate})) == [{33_031, 0.125}, {33_034, 0.2}]
  end

  test "released Haiku 5.5 counts cache writes in the full prompt threshold" do
    model = ReqLLM.model!("anthropic:claude-haiku-5-5")

    for {prompt, expected} <- [{100_000, 0.014132}, {100_001, 0.070656}] do
      priced = Cost.apply(mixed_usage(prompt - 66_065), model, pricing_context: @context)
      assert priced.pricing.status == :priced
      assert_in_delta priced.total_cost, expected, 1.0e-12
    end
  end

  test "released Sonnet 5.5 derives the one-hour write rate from base input" do
    model = ReqLLM.model!("anthropic:claude-sonnet-5-5")

    usage =
      Usage.normalize(%{
        input_tokens: 0,
        output_tokens: 0,
        input_includes_cached: false,
        cache_write_tokens: 1_000_000,
        cache_write_tokens_by_ttl: %{"5m" => 0, "1h" => 1_000_000}
      })

    priced = Cost.apply(usage, model, pricing_context: @context)
    assert priced.pricing.status == :priced
    assert priced.total_cost == 4.0
  end

  test "released cache tariffs cannot price writes with no duration breakdown" do
    for id <- ~w(claude-haiku-5-5 claude-sonnet-5-5) do
      model = ReqLLM.model!("anthropic:#{id}")

      usage =
        Usage.normalize(%{
          input_tokens: 14,
          output_tokens: 4,
          input_includes_cached: false,
          cache_write_tokens: 66_065
        })

      priced = Cost.apply(usage, model, pricing_context: @context)
      assert priced.pricing.status == :unknown
      refute Map.has_key?(priced, :total_cost)
    end
  end

  defp mixed_usage(input) do
    Usage.normalize(%{
      input_tokens: input,
      output_tokens: 4,
      input_includes_cached: false,
      cache_write_tokens: 66_065,
      cache_write_tokens_by_ttl: %{"5m" => 33_031, "1h" => 33_034}
    })
  end
end
