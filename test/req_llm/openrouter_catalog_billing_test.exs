defmodule ReqLLM.OpenRouterCatalogBillingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Usage.Cost

  test "released Mistral Medium 3.5 metadata prices cached prompt tokens" do
    model = ReqLLM.model!("openrouter:mistralai/mistral-medium-3-5")

    for {input, cached, output, expected} <- [
          {3357, 0, 887, 0.011688},
          {3972, 1792, 2149, 0.0220755},
          {3920, 3840, 0, 0.00588}
        ] do
      usage = %{
        input_tokens: input,
        cached_tokens: cached,
        output_tokens: output,
        total_tokens: input + output
      }

      assert {:ok, priced} = Cost.breakdown(usage, model)
      assert priced.pricing.status == :priced
      assert_in_delta priced.total_cost, expected, 1.0e-6
    end
  end
end
