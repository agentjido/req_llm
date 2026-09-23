defmodule ReqLLM.ConditionalPricingTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.Billing
  alias ReqLLM.Step.Usage
  alias ReqLLM.StreamServer
  alias ReqLLM.Usage.Cost

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    {:ok, loaded} =
      LLMDB.Loader.load(
        allow: %{deepseek: ["deepseek-v4-flash"]},
        deny: %{},
        prefer: [],
        custom: %{}
      )

    %{deepseek: loaded.models_by_key[{:deepseek, "deepseek-v4-flash"}]}
  end

  test "OpenAI selects a whole-request tier using cached prompt tokens" do
    model = ReqLLM.model!("openai:gpt-6-sol")
    context = %{api: "responses", service_tier: "default", regional_processing: false}

    at_boundary = %{
      input_tokens: 272_000,
      output_tokens: 100_000,
      cached_tokens: 20_000,
      cache_creation_tokens: 10_000
    }

    assert {:ok, short} = Billing.calculate(at_boundary, model, context)
    assert short.total == 1.513

    assert {:ok, long} =
             Billing.calculate(%{at_boundary | input_tokens: 272_001}, model, context)

    assert long.total == 2.526004
    assert Enum.find(long.line_items, &(&1.id == "token.input.long_context")).count == 242_001
    assert Enum.find(long.line_items, &(&1.id == "token.cache_read.long_context")).count == 20_000

    assert Enum.find(long.line_items, &(&1.id == "token.cache_write.long_context")).count ==
             10_000

    separate_input = %{
      input_tokens: 250_001,
      output_tokens: 100_000,
      cache_read_tokens: 22_000,
      input_includes_cached: false
    }

    assert {:ok, separate} = Billing.calculate(separate_input, model, context)
    assert Enum.any?(separate.line_items, &(&1.id == "token.input.long_context"))
    assert Enum.find(separate.line_items, &(&1.id == "token.input.long_context")).count == 250_001
  end

  test "processing and regional modifiers target selected rates exactly once" do
    model = ReqLLM.model!("openai:gpt-6-sol")
    usage = %{input_tokens: 272_001, output_tokens: 100_000, cached_tokens: 20_000}

    assert {:ok, standard} =
             Billing.calculate(usage, model,
               api: "responses",
               service_tier: "default",
               regional_processing: false
             )

    assert {:ok, flex} =
             Billing.calculate(usage, model,
               api: "responses",
               service_tier: "flex",
               regional_processing: true
             )

    assert_in_delta flex.total, standard.total * 0.5 * 1.1, 0.000002
    assert {:ok, nil} = Billing.calculate(usage, model, %{api: "responses"})
    assert {:ok, nil} = Billing.calculate(usage, model, %{api: "responses", service_tier: "auto"})
  end

  test "xAI long-context rate begins at exactly 200,000 prompt tokens" do
    model = ReqLLM.model!("xai:grok-4.7")
    context = %{service_tier: "standard", base_url: "https://api.x.ai/v1"}

    assert {:ok, short} =
             Billing.calculate(%{input_tokens: 199_999, output_tokens: 1_000}, model, context)

    assert short.total == 0.405998
    assert Enum.any?(short.line_items, &(&1.id == "token.input"))

    assert {:ok, long} =
             Billing.calculate(%{input_tokens: 200_000, output_tokens: 1_000}, model, context)

    assert long.total == 0.812
    assert Enum.any?(long.line_items, &(&1.id == "token.input.long_context"))
  end

  test "derived cache rate is resolved before token-wide modifiers" do
    model = ReqLLM.model!("anthropic:claude-fable-5-1")

    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_creation_tokens: 10_000,
      input_includes_cached: false
    }

    assert {:ok, charge} =
             Billing.calculate(usage, model,
               api: "batch",
               cache_ttl: "1h",
               inference_geo: "us"
             )

    write = Enum.find(charge.line_items, &(&1.id == "token.cache_write.1h"))
    assert write.rate == 11.0
    assert write.count == 10_000
    assert write.cost == 0.11
    assert {:ok, nil} = Billing.calculate(usage, model, %{api: "batch", inference_geo: "us"})
  end

  test "derived rates preserve the base unit price when their denominator differs" do
    model = %LLMDB.Model{
      provider: :test,
      id: "derived-units",
      pricing: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", rate: 2.0, per: 1_000_000},
          %{
            id: "token.cache_read",
            kind: "token",
            derives_from: "token.input",
            multiplier: 0.5,
            per: 1_000
          },
          %{id: "token.output", kind: "token", rate: 1.0, per: 1_000_000}
        ]
      }
    }

    assert {:ok, charge} =
             Billing.calculate(
               %{input_tokens: 1_000, output_tokens: 0, cached_tokens: 500},
               model
             )

    assert charge.total == 0.0015
    assert Enum.find(charge.line_items, &(&1.id == "token.cache_read")).rate == 0.001
  end

  test "mixed cache write durations are charged through disjoint groups" do
    model = ReqLLM.model!("anthropic:claude-fable-5-1")

    usage =
      ReqLLM.Usage.normalize(%{
        input_tokens: 1_000_000,
        output_tokens: 0,
        cache_creation_input_tokens: 10_000,
        cache_creation: %{ephemeral_5m_input_tokens: 4_000, ephemeral_1h_input_tokens: 6_000},
        input_includes_cached: false
      })

    assert usage.cache_write_tokens_by_ttl == %{"5m" => 4_000, "1h" => 6_000}

    assert {:ok, charge} =
             Billing.calculate(usage, model, %{api: "chat", inference_geo: "global"})

    writes = Enum.filter(charge.line_items, &String.starts_with?(&1.id, "token.cache_write"))
    assert Enum.map(writes, & &1.cost) |> Enum.sort() == [0.05, 0.12]
    assert charge.total == 10.17

    incomplete = %{usage | cache_write_tokens_by_ttl: %{"5m" => 4_000}}

    assert {:ok, nil} =
             Billing.calculate(incomplete, model, %{api: "chat", inference_geo: "global"})
  end

  test "time-dependent tariffs need a confirmed period", %{deepseek: model} do
    usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}

    assert {:ok, nil} = Billing.calculate(usage, model)
    assert {:ok, off_peak} = Billing.calculate(usage, model, %{pricing_period: "off_peak"})
    assert {:ok, peak} = Billing.calculate(usage, model, %{pricing_period: "peak"})
    assert off_peak.total == 0.75
    assert peak.total == 1.5
    assert {:ok, nil} = Billing.calculate(usage, model, %{pricing_period: "unconfirmed"})
  end

  test "Coding Plan credits never populate USD cost fields" do
    model = ReqLLM.model!("zai_coding_plan:glm-5.3")
    usage = %{input_tokens: 10_000, output_tokens: 10_000, cached_tokens: 2_000}

    context = %{
      billing_product: "coding_plan",
      plan_generation: "token_credits",
      pricing_period: "peak"
    }

    assert {:ok, nil} = Billing.calculate(usage, model)
    assert {:ok, credits} = Billing.calculate(usage, model, context)
    assert credits.currency == "credits"
    assert credits.total == 29.86
    refute Map.has_key?(credits, :input_cost)

    priced = usage |> ReqLLM.Usage.normalize() |> Cost.apply(model, pricing_context: context)
    assert priced.pricing == %{status: :priced, currency: "credits", total: 29.86}
    refute Map.has_key?(priced, :total_cost)
    refute Map.has_key?(priced, :input_cost)
  end

  test "Google catalog tiers replace the old local overlay and storage uses its own meter" do
    model = ReqLLM.model!("google:gemini-3.1-pro-preview")
    ids = Enum.map(model.pricing.components, & &1.id)
    refute Enum.any?(ids, &String.ends_with?(&1, ".standard_context"))

    context = %{api: "generate_content", service_tier: "standard", cache_type: "explicit"}
    usage = %{input_tokens: 200_000, output_tokens: 100_000, cache_storage_token_hours: 500_000}

    assert {:ok, cost} = Billing.calculate(usage, model, context)
    assert cost.total == 3.85
    assert Enum.find(cost.line_items, &(&1.id == "storage.cache")).cost == 2.25

    assert {:ok, nil} =
             Billing.calculate(Map.delete(usage, :cache_storage_token_hours), model, context)
  end

  test "unknown usage, incomplete bands, and unsupported modifiers have no numeric charge" do
    model = %LLMDB.Model{
      provider: :test,
      id: "banded",
      pricing: %{
        currency: "USD",
        components: [
          %{
            id: "token.input",
            kind: "token",
            per: 1_000_000,
            rate: 1.0,
            applies_when: %{input_tokens: %{lte: 100}}
          },
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 2.0},
          %{
            id: "pricing.special",
            kind: "other",
            applies_to: ["token.*.unsupported"],
            applies_when: %{service_tier: "special"},
            multiplier: 1.1
          }
        ]
      }
    }

    assert {:ok, nil} = Billing.calculate(%{output_tokens: 5}, model)
    assert {:ok, nil} = Billing.calculate(%{input_tokens: 5, output_tokens: 5}, model, [:bad])

    nil_input = ReqLLM.Usage.normalize(%{input_tokens: nil, output_tokens: 5})
    assert {:ok, nil} = Billing.calculate(nil_input, model)
    assert {:ok, nil} = Billing.calculate(%{input_tokens: 50.5, output_tokens: 5}, model)

    assert {:ok, nil} =
             Billing.calculate(%{input_tokens: 101, output_tokens: 5}, model, %{
               service_tier: "standard"
             })

    assert {:ok, nil} =
             Billing.calculate(%{input_tokens: 50, output_tokens: 5}, model, %{
               service_tier: "special"
             })
  end

  test "an unresolved storage modifier cannot be skipped for a storage-only charge" do
    model = %LLMDB.Model{
      provider: :test,
      id: "storage-only",
      pricing: %{
        currency: "USD",
        components: [
          %{
            id: "storage.cache",
            kind: "storage",
            meter: "cache_storage_token_hours",
            per: 1_000_000,
            rate: 2.0
          },
          %{
            id: "pricing.storage_region",
            kind: "other",
            applies_to: ["storage.cache"],
            applies_when: %{region: "us"},
            multiplier: 1.5
          }
        ]
      }
    }

    usage = %{input_tokens: 0, output_tokens: 0, cache_storage_token_hours: 1_000_000}
    assert {:ok, nil} = Billing.calculate(usage, model)
    assert {:ok, priced} = Billing.calculate(usage, model, %{region: "us"})
    assert priced.total == 3.0
  end

  test "MiniMax requires a provider-confirmed context band" do
    model = ReqLLM.model!("minimax:MiniMax-M3")
    usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}

    assert {:ok, nil} = Billing.calculate(usage, model, %{service_tier: "standard"})

    assert {:ok, charge} =
             Billing.calculate(usage, model, %{context_tier: "gt_512k", service_tier: "priority"})

    assert charge.total == 4.5
  end

  test "an unpriced gateway route does not inherit a first-party charge" do
    gateway = %LLMDB.Model{provider: :openrouter, id: "openai/gpt-6-sol", pricing: nil}
    usage = %{input_tokens: 100_000, output_tokens: 10_000}

    assert {:ok, nil} =
             Billing.calculate(usage, gateway, %{
               api: "responses",
               service_tier: "default",
               regional_processing: false
             })

    assert %{pricing: %{status: :unknown}} =
             usage |> ReqLLM.Usage.normalize() |> Cost.apply(gateway)
  end

  test "ordinary response uses the caller's confirmed period", %{deepseek: model} do
    request = %Req.Request{
      private: %{req_llm_model: model, req_llm_pricing_context: %{pricing_period: "peak"}}
    }

    response = %Req.Response{
      body: %{"usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000}}
    }

    {_request, priced} = Usage.handle({request, response})
    assert priced.private.req_llm.usage.pricing == %{status: :priced, currency: "USD", total: 1.5}
    assert priced.private.req_llm.usage.total_cost == 1.5

    {_request, unknown} = Usage.handle({%{request | private: %{req_llm_model: model}}, response})
    assert unknown.private.req_llm.usage.pricing.status == :unknown
    refute Map.has_key?(unknown.private.req_llm.usage, :total_cost)
  end

  test "streaming metadata prices merged usage with the confirmed period", %{deepseek: model} do
    server = start_server(model: model, pricing_context: %{pricing_period: "peak"})
    _task = mock_http_task(server)

    for usage <- [%{"prompt_tokens" => 1_000_000}, %{"completion_tokens" => 1_000_000}] do
      payload = Jason.encode!(%{"usage" => usage})
      assert :ok = StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
    end

    assert :ok = StreamServer.http_event(server, :done)
    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    assert metadata.usage.pricing == %{status: :priced, currency: "USD", total: 1.5}
    assert metadata.usage.total_cost == 1.5
    StreamServer.cancel(server)
  end

  test "a later stream usage update cannot erase an earlier invalid cache count" do
    model = ReqLLM.model!("openai:gpt-4o")

    invalid =
      ReqLLM.Usage.normalize(%{
        input_tokens: 100,
        output_tokens: 10,
        cached_tokens: 150
      })

    valid =
      ReqLLM.Usage.normalize(%{
        input_tokens: 100,
        output_tokens: 10,
        cached_tokens: 50
      })

    merged = ReqLLM.Usage.merge(invalid, valid)
    assert merged.billing_usage_complete == false
    assert %{pricing: %{status: :unknown}} = Cost.apply(merged, model)
  end
end
