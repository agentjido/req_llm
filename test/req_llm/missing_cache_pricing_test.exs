defmodule ReqLLM.MissingCachePricingTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Usage.Cost

  defmodule InProcess do
    def stream_transport(_, _), do: :in_process

    def attach_in_process_stream(_, _, opts) do
      chunks = [
        ReqLLM.StreamChunk.text("done"),
        ReqLLM.StreamChunk.meta(%{usage: opts[:test_usage], finish_reason: :stop})
      ]

      {:ok, %ReqLLM.Provider.InProcessStream{stream: chunks}}
    end
  end

  def handle_telemetry(_event, measurements, metadata, owner),
    do: send(owner, {:pricing_telemetry, measurements, metadata})

  defp model do
    %LLMDB.Model{
      provider: :openrouter,
      id: "mistralai/mistral-medium-3-5",
      pricing: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.5},
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 7.5}
        ]
      }
    }
  end

  defp usage do
    %{input_tokens: 3972, cached_tokens: 1792, output_tokens: 2149, total_tokens: 6121}
  end

  test "cached tokens without a rate expose the missing component and omit all costs" do
    assert {:ok, %{pricing: %{status: :unknown, reason: {:missing_component, :cache_read}}}} =
             Cost.breakdown(usage(), model())

    assert {:ok, nil} = ReqLLM.Billing.calculate(usage(), model())

    old_costs = %{
      total_cost: 10.0,
      input_cost: 5.0,
      output_cost: 5.0,
      reasoning_cost: 0.0,
      cost: %{total: 10.0}
    }

    result = Cost.apply(Map.merge(usage(), old_costs), model())
    assert result.pricing == %{status: :unknown, reason: {:missing_component, :cache_read}}
    assert Map.take(result, Map.keys(old_costs)) == %{}
  end

  test "uncached requests and explicit cache pricing still produce costs" do
    uncached = %{input_tokens: 3357, cached_tokens: 0, output_tokens: 887, total_tokens: 4244}
    result = Cost.apply(uncached, model())
    assert result.pricing.status == :priced
    assert_in_delta result.total_cost, 0.011688, 1.0e-10

    model = model()
    cache_rate = %{id: "token.cache_read", kind: "token", per: 1_000_000, rate: 1.5}

    model = %{
      model
      | pricing: %{model.pricing | components: model.pricing.components ++ [cache_rate]}
    }

    result = Cost.apply(usage(), model)
    assert result.pricing.status == :priced
    assert_in_delta result.total_cost, 0.0220755, 1.0e-6
  end

  test "sync and stream responses and telemetry expose the missing cache rate" do
    id = "missing-cache-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, [:req_llm, :token_usage], &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    model = model()

    body = %ReqLLM.Response{
      id: "cache-test",
      model: model.id,
      context: ReqLLM.Context.new([]),
      usage: usage()
    }

    request = %Req.Request{options: %{}, private: %{req_llm_model: model}}
    {_, sync} = ReqLLM.Step.Usage.handle({request, %Req.Response{body: body}})
    expected = %{status: :unknown, reason: {:missing_component, :cache_read}}
    assert sync.body.usage.pricing == expected
    assert sync.private.req_llm.usage.pricing == expected
    refute Map.has_key?(sync.body.usage, :total_cost)
    assert_receive {:pricing_telemetry, %{pricing: ^expected}, %{mode: :sync}}

    assert {:ok, stream} =
             ReqLLM.Streaming.start_stream(InProcess, model, ReqLLM.Context.new([]),
               test_usage: usage()
             )

    on_exit(fn -> ReqLLM.StreamResponse.close(stream) end)
    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream)
    assert response.usage.pricing == expected
    refute Map.has_key?(response.usage, :total_cost)
    assert_receive {:pricing_telemetry, %{tokens: %{pricing: ^expected}}, %{mode: :stream}}
  end
end
