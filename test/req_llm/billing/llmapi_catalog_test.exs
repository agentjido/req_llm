defmodule ReqLLM.LLMAPICatalogBillingTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.Billing.{Money, Reference}

  @model "llmapi:gpt-4o-mini"
  @fixture_dir "test/support/fixtures/llmapi/gpt_4o_mini"

  test "the released catalog routes LLM API through the shared adapter" do
    assert {:error, _} = ReqLLM.Providers.get(:llmapi)
    assert {:ok, provider} = LLMDB.provider(:llmapi)
    assert provider.runtime.base_url == "https://api.llmapi.ai/v1"
    assert provider.runtime.auth.env == ["LLM_API_KEY", "LLMAPI_API_KEY"]
    model = ReqLLM.model!(@model)
    assert {:ok, ReqLLM.Providers.CatalogGateway} = ReqLLM.ProviderDispatch.get(model, :chat)
    assert {:ok, ReqLLM.Providers.CatalogGateway} = ReqLLM.ProviderDispatch.get(model, :object)
    refute ReqLLM.ProviderTest.Comprehensive.supports_text_streaming?("llmapi:o3")
  end

  test "buffered and streamed public responses retain gateway usage, prices and telemetry" do
    handler = "llmapi-billing-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:req_llm, :token_usage],
        fn _, measurements, metadata, _ ->
          send(owner, {:usage, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, buffered} =
             ReqLLM.generate_text(@model, "Hello world!",
               fixture: "basic",
               temperature: 0.0,
               max_tokens: 50,
               seed: 42
             )

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system("You are a helpful, creative assistant."),
        ReqLLM.Context.user("Say hello in one short, imaginative sentence.")
      ])

    assert {:ok, stream} =
             ReqLLM.stream_text(@model, context,
               fixture: "streaming",
               temperature: 0.9,
               max_tokens: 100,
               top_p: 0.8
             )

    assert {:ok, streamed} = ReqLLM.StreamResponse.to_response(stream)

    for {name, response} <- [{"basic", buffered}, {"streaming", streamed}] do
      raw = Path.join(@fixture_dir, name <> ".json") |> File.read!() |> Jason.decode!()
      usage = Reference.response_body(raw)["usage"]
      assert raw["request"]["canonical_json"]["model"] == "gpt-4o-mini"
      assert raw["request"]["url"] == "https://api.llmapi.ai/v1/chat/completions"
      assert response.usage.input_tokens == usage["prompt_tokens"]
      assert response.usage.output_tokens == usage["completion_tokens"]
      assert response.usage.total_tokens == usage["total_tokens"]
      expected = independent_total(usage)
      assert Money.observed(response.usage.total_cost) == expected
      assert_receive {:usage, %{cost: cost}, %{provider: :llmapi}}
      assert Money.observed(cost) == expected
    end
  end

  test "all live scenario captures agree with independent rates and provider cost fields" do
    model = ReqLLM.model!(@model)
    paths = Path.wildcard(Path.join(@fixture_dir, "*.json"))
    assert length(paths) == 11

    for path <- paths do
      raw = path |> File.read!() |> Jason.decode!()
      usage = Reference.response_body(raw)["usage"]
      assert is_map(usage), "missing usage in #{path}"
      expected = independent_total(usage)
      assert {:ok, billing} = ReqLLM.Billing.calculate(ReqLLM.Usage.normalize(usage), model)
      assert Money.observed(billing.total) == expected

      reported = Money.observed(usage["cost_usd_input"] + usage["cost_usd_output"])
      assert abs(reported - expected) <= 1
    end
  end

  defp independent_total(usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

    Money.micros("0.15", usage["prompt_tokens"] - cached, 1_000_000) +
      Money.micros("0.075", cached, 1_000_000) +
      Money.micros("0.60", usage["completion_tokens"], 1_000_000)
  end
end
