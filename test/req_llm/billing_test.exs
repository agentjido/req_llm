defmodule ReqLLM.BillingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Billing

  test "returns nil when components are empty" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{components: []},
      cost: %{input: 1.0, output: 2.0}
    }

    usage = %{
      input: 1_000_000,
      output: 500_000,
      input_tokens: 1_000_000,
      output_tokens: 500_000
    }

    assert {:ok, nil} = Billing.calculate(usage, model)
  end

  test "skips components missing per or rate" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", per: 1_000_000}
        ]
      }
    }

    usage = %{
      input: 1_000_000,
      output: 1_000_000,
      input_tokens: 1_000_000,
      output_tokens: 1_000_000
    }

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.tokens == 1.0
    assert cost.total == 1.0
    assert cost.input_cost == 1.0
    assert cost.output_cost == 0.0
  end

  test "skips components with unsupported kinds" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{id: "request.base", kind: "request", per: 1, rate: 1.0}
        ]
      }
    }

    usage = %{}

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.total == 0.0
    assert cost.tokens == 0.0
    assert cost.tools == 0.0
    assert cost.images == 0.0
  end

  test "calculates tool costs with string keys" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        "components" => [
          %{
            "id" => "tool.web_search",
            "kind" => "tool",
            "tool" => "web_search",
            "unit" => "query",
            "per" => 1,
            "rate" => 0.5
          }
        ]
      }
    }

    usage = %{"tool_usage" => %{"web_search" => %{"count" => 2, "unit" => "query"}}}

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.tools == 1.0
    assert cost.total == 1.0
  end

  test "skips tool costs when unit mismatches" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{
            id: "tool.web_search",
            kind: "tool",
            tool: :web_search,
            unit: :query,
            per: 1,
            rate: 1.0
          }
        ]
      }
    }

    usage = %{tool_usage: %{web_search: %{count: 3, unit: :source}}}

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.tools == 0.0
    assert cost.total == 0.0
  end

  test "subtracts cached tokens from input when input includes cached tokens" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.cache_read", kind: "token", per: 1_000_000, rate: 0.1},
          %{id: "token.cache_write", kind: "token", per: 1_000_000, rate: 0.2}
        ]
      }
    }

    usage = %{
      input_tokens: 1_000,
      cached_tokens: 200,
      cache_creation_tokens: 100,
      input_includes_cached: true
    }

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.tokens == 0.00074
    assert cost.total == 0.00074
  end

  test "calculates reasoning_cost separately when token.reasoning component exists" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 2.0},
          %{id: "token.reasoning", kind: "token", per: 1_000_000, rate: 3.0}
        ]
      }
    }

    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 500_000,
      reasoning_tokens: 200_000
    }

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.input_cost == 1.0
    assert cost.output_cost == 1.6
    assert cost.reasoning_cost == 0.6
    assert cost.total == 2.6
  end

  test "reasoning_cost is zero when no reasoning tokens" do
    model = %LLMDB.Model{
      provider: :test,
      id: "m1",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 2.0}
        ]
      }
    }

    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 500_000
    }

    assert {:ok, cost} = Billing.calculate(usage, model)
    assert cost.input_cost == 1.0
    assert cost.output_cost == 1.0
    assert cost.reasoning_cost == 0.0
    assert cost.total == 2.0
  end
end
