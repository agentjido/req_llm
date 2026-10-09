defmodule ReqLLM.Usage.NormalizeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Usage.Normalize

  test "invalid reported flags remain unpriced and can merge without an error" do
    model = ReqLLM.model!("openai:gpt-5-nano")

    for reported <- [true, false, [], "invalid", %{input: "yes", output: true}] do
      raw = %{input_tokens: 10, output_tokens: 2, usage_reported: reported}
      normalized = ReqLLM.Usage.normalize(raw)
      assert normalized.usage_reported == %{input: false, output: false}
      refute normalized.billing_usage_complete
      assert {:ok, nil} = ReqLLM.Billing.calculate(raw, model)
      assert {:ok, nil} = ReqLLM.Billing.calculate(normalized, model)

      merged = ReqLLM.Usage.merge(ReqLLM.Usage.normalize(%{input_tokens: 10}), normalized)
      refute merged.billing_usage_complete
      assert {:ok, nil} = ReqLLM.Billing.calculate(merged, model)
    end
  end

  test "false token counts stay malformed through repeated normalization" do
    for key <- [:input_tokens, :output_tokens, :reasoning_tokens] do
      usage = %{input_tokens: 10, output_tokens: 2} |> Map.put(key, false)
      normalized = ReqLLM.Usage.normalize(usage)
      assert normalized[key] == false
      assert ReqLLM.Usage.normalize(normalized)[key] == false
    end
  end

  test "invalid cache and reasoning flags remain unpriced" do
    model = ReqLLM.model!("openai:gpt-4o")

    for key <- [:input_includes_cached, :add_reasoning_to_cost],
        invalid <- ["no", 0, [], %{}] do
      raw = %{input_tokens: 1000, output_tokens: 200, cached_tokens: 500, reasoning_tokens: 10}
      raw = Map.put(raw, key, invalid)
      normalized = ReqLLM.Usage.normalize(raw)
      assert normalized[key] == invalid
      refute normalized.billing_usage_complete
      assert {:ok, nil} = ReqLLM.Billing.calculate(raw, model)
      assert ReqLLM.Usage.Cost.apply(normalized, model).pricing.status == :unknown
    end
  end

  test "a malformed later counter cannot leave a known stream price" do
    model = ReqLLM.model!("openai:gpt-4o")
    initial = ReqLLM.Usage.normalize(%{input_tokens: 10, output_tokens: 2})

    for key <- [:input_tokens, :output_tokens, :reasoning_tokens],
        invalid <- [false, "invalid", -1, 1.5] do
      incoming =
        ReqLLM.Usage.normalize(Map.put(%{input_tokens: 10, output_tokens: 2}, key, invalid))

      merged = ReqLLM.Usage.merge(initial, incoming)

      refute merged.billing_usage_complete
      assert ReqLLM.Usage.Cost.apply(merged, model).pricing.status == :unknown
      assert ReqLLM.Usage.Cost.apply(incoming, model).pricing.status == :unknown
    end
  end

  test "cache duration maps retain empty and invalid provider facts" do
    for groups <- [%{}, %{"5m" => nil}, %{"5m" => false}, "invalid", []] do
      normalized =
        ReqLLM.Usage.normalize(%{
          input_tokens: 100,
          output_tokens: 2,
          cache_creation_tokens: 10,
          cache_write_tokens_by_ttl: groups
        })

      assert normalized.cache_write_tokens_by_ttl == groups
      assert ReqLLM.Usage.normalize(normalized).cache_write_tokens_by_ttl == groups

      assert {:ok, nil} =
               ReqLLM.Billing.calculate(
                 normalized,
                 ReqLLM.model!("anthropic:claude-fable-5-1"),
                 %{api: "chat", inference_geo: "global", cache_ttl: "5m"}
               )
    end
  end

  test "partial native duration maps keep only the reported duration" do
    normalized =
      ReqLLM.Usage.normalize(%{
        input_tokens: 100,
        output_tokens: 2,
        cache_creation_input_tokens: 30,
        cache_creation: %{ephemeral_5m_input_tokens: "10"},
        input_includes_cached: false
      })

    assert normalized.cache_write_tokens_by_ttl == %{"5m" => 10}

    assert {:ok, nil} =
             ReqLLM.Billing.calculate(normalized, ReqLLM.model!("anthropic:claude-fable-5-1"), %{
               api: "chat",
               inference_geo: "global"
             })
  end

  test "unexpected native duration fields remain available for billing validation" do
    normalized =
      ReqLLM.Usage.normalize(%{
        input_tokens: 100,
        output_tokens: 2,
        cache_creation_input_tokens: 30,
        cache_creation: %{ephemeral_5m_input_tokens: 10, future_ttl: 20},
        input_includes_cached: false
      })

    assert normalized.cache_write_tokens_by_ttl == %{"5m" => 10, "future_ttl" => 20}

    assert {:ok, nil} =
             ReqLLM.Billing.calculate(normalized, ReqLLM.model!("anthropic:claude-fable-5-1"), %{
               api: "chat",
               inference_geo: "global"
             })
  end

  describe "input_includes_cached" do
    test "honors an explicit false flag and does not clamp cached tokens" do
      usage = %{
        input_tokens: 12,
        output_tokens: 5,
        cached_tokens: 4000,
        cache_creation_tokens: 900,
        input_includes_cached: false
      }

      normalized = Normalize.normalize(usage)

      assert normalized.input_includes_cached == false
      assert normalized.cache_read_tokens == 4000
      assert normalized.cache_write_tokens == 900
      assert normalized.cached_tokens == 4000
      assert normalized.cache_creation_tokens == 900
    end

    test "survives a second normalization" do
      usage = %{
        input_tokens: 12,
        output_tokens: 5,
        cached_tokens: 4000,
        input_includes_cached: false
      }

      twice = usage |> Normalize.normalize() |> Normalize.normalize()

      assert twice.cache_read_tokens == 4000
      assert twice.cached_tokens == 4000
    end

    test "normalizes explicit cache read and write counters" do
      normalized =
        Normalize.normalize(%{
          input_tokens: 12,
          output_tokens: 5,
          cache_read_tokens: 4000,
          cache_write_tokens: 900,
          input_includes_cached: false
        })

      assert normalized.cache_read_tokens == 4000
      assert normalized.cache_write_tokens == 900
      assert normalized.cached_tokens == 4000
      assert normalized.cache_creation_tokens == 900
    end

    test "honors an explicit true flag" do
      usage = %{
        input_tokens: 5000,
        output_tokens: 5,
        cached_tokens: 4000,
        input_includes_cached: true
      }

      assert Normalize.normalize(usage).input_includes_cached == true
    end

    test "keeps the format heuristic when the flag is absent" do
      canonical_only = %{input_tokens: 12, output_tokens: 5, cached_tokens: 4000}
      assert Normalize.normalize(canonical_only).input_includes_cached == true

      anthropic = %{"input_tokens" => 12, "output_tokens" => 5, "cache_read_input_tokens" => 4000}
      assert Normalize.normalize(anthropic).input_includes_cached == false
    end
  end

  describe "compute_units" do
    test "keeps zero compute units without making billing incomplete" do
      for value <- [0, "0"] do
        normalized =
          Normalize.normalize(%{
            input_tokens: 10,
            output_tokens: 2,
            compute_units: value
          })

        assert normalized.compute_units == 0
        assert normalized.billing_usage_complete
      end
    end

    test "keeps positive compute units and marks billing incomplete" do
      normalized =
        Normalize.normalize(%{
          "input_tokens" => 10,
          "output_tokens" => 2,
          "compute_units" => 7
        })

      assert normalized.compute_units == 7
      refute normalized.billing_usage_complete
      refute Normalize.normalize(normalized).billing_usage_complete
    end

    test "keeps malformed compute units and marks billing incomplete" do
      for value <- ["unknown", -1, 0.0] do
        normalized =
          Normalize.normalize(%{
            input_tokens: 10,
            output_tokens: 2,
            compute_units: value
          })

        assert normalized.compute_units == value
        refute normalized.billing_usage_complete
      end
    end

    test "does not add compute units when the provider omits them" do
      normalized = Normalize.normalize(%{input_tokens: 10, output_tokens: 2})

      refute Map.has_key?(normalized, :compute_units)
    end
  end
end
