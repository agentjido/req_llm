defmodule ReqLLM.Usage.ProviderCostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Step.Usage, as: UsageStep
  alias ReqLLM.Usage.Cost
  alias ReqLLM.Usage.ProviderCost

  @request_id "provider-cost-test"

  defp openrouter_usage(overrides) do
    Map.merge(
      %{"prompt_tokens" => 1_000, "completion_tokens" => 200, "total_tokens" => 1_200},
      overrides
    )
  end

  defp priced_request(model_spec) do
    model = ReqLLM.model!(model_spec)

    UsageStep.attach(
      %Req.Request{
        private: %{req_llm_model: model, req_llm_request_id: @request_id},
        options: [model: model]
      },
      model
    )
  end

  defp price(raw_body, model_spec) do
    request = priced_request(model_spec)

    {_request, response} =
      UsageStep.handle({request, %Req.Response{status: 200, body: raw_body, private: %{}}})

    response
  end

  defp price_decoded_response(usage, model_spec) do
    request = priced_request(model_spec)

    body = %ReqLLM.Response{
      id: "provider-cost",
      model: model_spec,
      context: ReqLLM.Context.new([]),
      message: nil,
      usage: usage,
      finish_reason: :stop,
      provider_meta: %{},
      stream?: false,
      stream: nil
    }

    {_request, response} =
      UsageStep.handle({request, %Req.Response{status: 200, body: body, private: %{}}})

    response
  end

  defp applied(raw_usage) do
    raw_usage
    |> ReqLLM.Usage.normalize()
    |> Cost.apply(ReqLLM.model!("openai:gpt-4o-mini"))
  end

  describe "from_usage/1" do
    test "reads the charge and keeps the upstream share of a BYOK request apart" do
      assert ProviderCost.from_usage(openrouter_usage(%{"cost" => 0.0042, "is_byok" => false})) ==
               %{cost: 0.0042, byok: false, upstream_cost: nil}

      byok =
        openrouter_usage(%{
          "cost" => 0.01,
          "is_byok" => true,
          "cost_details" => %{"upstream_inference_cost" => 0.002}
        })

      assert ProviderCost.from_usage(byok) == %{cost: 0.01, byok: true, upstream_cost: 0.002}
    end

    test "derives the upstream share from its parts when the total is null" do
      usage =
        openrouter_usage(%{
          "cost" => 0.01,
          "is_byok" => true,
          "cost_details" => %{
            "upstream_inference_cost" => nil,
            "upstream_inference_prompt_cost" => 0.0015,
            "upstream_inference_completions_cost" => 0.0005
          }
        })

      assert ProviderCost.from_usage(usage) == %{cost: 0.01, byok: true, upstream_cost: 0.002}
    end

    test "a charge without is_byok counts as one the account paid for" do
      assert ProviderCost.from_usage(openrouter_usage(%{"cost" => 0.01})) ==
               %{cost: 0.01, byok: false, upstream_cost: nil}
    end

    test "a usage map without a usable charge is left alone" do
      for overrides <- [
            %{},
            %{"cost" => nil, "is_byok" => false},
            %{"cost" => -1, "is_byok" => false},
            %{"cost" => "0.01", "is_byok" => false}
          ] do
        assert ProviderCost.from_usage(openrouter_usage(overrides)) == nil
      end
    end
  end

  test "normalizing an already normalized usage keeps the accounting" do
    once = ReqLLM.Usage.normalize(openrouter_usage(%{"cost" => 0.0042, "is_byok" => false}))

    assert once.provider_cost == %{cost: 0.0042, byok: false, upstream_cost: nil}
    assert ReqLLM.Usage.normalize(once) == once
  end

  describe "a stored accounting" do
    test "is validated like a raw one" do
      assert ProviderCost.validate(%{cost: -1, byok: false, upstream_cost: nil}) == nil

      assert ProviderCost.validate(%{cost: 0.01, byok: true, upstream_cost: -0.002}) ==
               %{cost: 0.01, byok: true, upstream_cost: nil}

      usage = %{input_tokens: 10, output_tokens: 2, provider_cost: %{cost: -0.5, byok: false}}
      refute Map.has_key?(Cost.apply(usage, nil), :total_cost)
    end

    test "is read through string keys" do
      decoded = %{"cost" => 0.01, "byok" => true, "upstream_cost" => 0.002}

      assert ProviderCost.validate(decoded) == %{cost: 0.01, byok: true, upstream_cost: 0.002}

      assert ProviderCost.from_usage(%{provider_cost: decoded}) ==
               %{cost: 0.01, byok: true, upstream_cost: 0.002}
    end
  end

  describe "cost application" do
    test "the reported charge replaces the catalog estimate" do
      priced = applied(openrouter_usage(%{"cost" => 0.0042, "is_byok" => false}))

      assert priced.total_cost == 0.0042
      assert priced.pricing == %{status: :priced, currency: "USD", total: 0.0042}
    end

    test "a BYOK total is the charge alone; the upstream share stays separate" do
      priced =
        applied(
          openrouter_usage(%{
            "cost" => 0.01,
            "is_byok" => true,
            "cost_details" => %{"upstream_inference_cost" => 0.002}
          })
        )

      assert priced.total_cost == 0.01
      assert priced.provider_cost == %{cost: 0.01, byok: true, upstream_cost: 0.002}
    end

    test "a request the catalog cannot price still carries the reported total" do
      priced =
        applied(
          openrouter_usage(%{"cost" => 0.0042, "is_byok" => false})
          |> Map.put("prompt_tokens", nil)
        )

      assert priced.total_cost == 0.0042
      assert priced.pricing == %{status: :priced, currency: "USD", total: 0.0042}
    end

    test "a usage map without accounting keeps the catalog estimate" do
      priced = applied(openrouter_usage(%{}))

      assert is_number(priced.total_cost)
      refute priced.total_cost == 0.0042
      refute Map.has_key?(priced, :provider_cost)
    end

    test "a streamed chunk without the accounting does not erase one an earlier chunk reported" do
      with_cost =
        ReqLLM.Usage.normalize(openrouter_usage(%{"cost" => 0.0042, "is_byok" => false}))

      without = ReqLLM.Usage.normalize(%{"prompt_tokens" => 1_000, "completion_tokens" => 200})

      merged = without |> ReqLLM.Usage.merge(with_cost) |> ReqLLM.Usage.merge(without)

      assert merged.provider_cost == %{cost: 0.0042, byok: false, upstream_cost: nil}
      assert Cost.apply(merged, ReqLLM.model!("openai:gpt-4o-mini")).total_cost == 0.0042
    end
  end

  test "the response usage carries the reported charge" do
    response =
      price_decoded_response(
        openrouter_usage(%{"cost" => 0.0042, "is_byok" => false}),
        "openai:gpt-4o-mini"
      )

    assert response.body.usage.total_cost == 0.0042
    assert response.body.usage.provider_cost == %{cost: 0.0042, byok: false, upstream_cost: nil}
  end

  describe "token-usage telemetry" do
    setup do
      test_pid = self()
      handler_id = "provider-cost-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:req_llm, :token_usage],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:token_usage, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "one event reports the reported charge as both cost and total_cost" do
      capture_log(fn ->
        price(
          %{"usage" => openrouter_usage(%{"cost" => 0.0042, "is_byok" => false})},
          "openai:gpt-4o-mini"
        )
      end)

      assert_receive {:token_usage, [:req_llm, :token_usage], measurements,
                      %{request_id: @request_id}},
                     1_000

      assert measurements.cost == 0.0042
      assert measurements.total_cost == 0.0042

      assert measurements.tokens.provider_cost == %{
               cost: 0.0042,
               byok: false,
               upstream_cost: nil
             }

      refute Map.has_key?(measurements, :provider_cost)
    end
  end
end
