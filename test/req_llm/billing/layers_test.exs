defmodule ReqLLM.Billing.LayersTest do
  use ExUnit.Case, async: true
  import ReqLLM.Test.StreamServerHelpers
  alias ReqLLM.Test.Billing.{Audit, Reference, Run, Samples}

  @moduletag :billing

  for sample <- Samples.all(), Samples.selected?(sample) do
    @tag billing_case: sample.case_id, billing_layer: "capture", model: sample.model
    test "#{sample.case_id}: raw provider fields survive transcript storage" do
      sample = unquote(Macro.escape(sample))
      raw = sample |> Samples.transcript() |> ReqLLM.Test.Transcript.to_map()
      assert raw["response"]["body"] == sample.body
      assert raw["captured_at"] != nil
      assert Reference.response_body(raw) == sample.body
    end

    @tag billing_case: sample.case_id, billing_layer: "pricing", model: sample.model
    test "#{sample.case_id}: independent reference matches hand arithmetic and native pricing" do
      sample = unquote(Macro.escape(sample))
      reference = Samples.reference(sample)

      if sample.expected == "unknown" do
        assert reference["status"] == "unknown"
      else
        assert reference["total"] == sample.expected
      end

      usage = Samples.buffered(sample).usage |> Run.stringify()
      assert Audit.compare(reference, usage)["status"] == "passed"
    end

    @tag billing_case: sample.case_id, billing_layer: "normalization", model: sample.model
    test "#{sample.case_id}: normalized input and output preserve supplier counts" do
      sample = unquote(Macro.escape(sample))
      normalized = ReqLLM.Usage.normalize(Samples.buffered(sample).usage)
      assert normalized.input_tokens == sample.body["usage"]["input_tokens"]
      assert normalized.output_tokens == sample.body["usage"]["output_tokens"]

      if sample.case_id == "mixed_cache_ttl" do
        assert normalized.cache_write_tokens_by_ttl == %{"5m" => 4000, "1h" => 6000}
      end
    end

    if sample.case_id != "compact_unknown" do
      @tag billing_case: sample.case_id, billing_layer: "pipeline", model: sample.model
      test "#{sample.case_id}: split and batched source events give the buffered price" do
        Process.flag(:trap_exit, true)
        sample = unquote(Macro.escape(sample))
        model = ReqLLM.model!(sample.model)
        buffered = Samples.buffered(sample)

        for batched <- [true, false] do
          provider =
            if model.provider == :openai,
              do: ReqLLM.Providers.OpenAI,
              else: ReqLLM.Providers.Anthropic

          server =
            start_server(
              provider_mod: provider,
              model: model,
              pricing_context: %{api: "chat", inference_geo: "global"}
            )

          mock_http_task(server)
          ReqLLM.StreamServer.set_fixture_context(server, %{url: sample.request["url"]}, %{})
          messages = Samples.events(sample) |> Enum.map(&"data: #{Jason.encode!(&1)}\n\n")
          data = if batched, do: [Enum.join(messages)], else: messages
          Enum.each(data, &ReqLLM.StreamServer.http_event(server, {:data, &1}))
          ReqLLM.StreamServer.http_event(server, :done)
          assert {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server, 1000)
          assert metadata.usage.pricing == buffered.usage.pricing
          assert metadata.usage[:total_cost] == buffered.usage[:total_cost]
          ReqLLM.StreamServer.cancel(server)
        end
      end
    end
  end

  @tag billing_case: "returned_service_tier", billing_layer: "adversarial"
  test "invalid returned tiers cannot become a known bill" do
    sample = Samples.sample("returned_service_tier", "openai:gpt-6-luna")

    for invalid <- [nil, false, "auto", [], %{}] do
      changed = %{sample | body: Map.put(sample.body, "service_tier", invalid)}
      assert Samples.reference(changed)["status"] == "unknown"
      assert Samples.buffered(changed).usage.pricing.status == :unknown
    end
  end

  @tag billing_case: "mixed_cache_ttl", billing_layer: "adversarial"
  test "incomplete duration maps remain unpriced through stream merges" do
    sample = Samples.sample("mixed_cache_ttl", "anthropic:claude-haiku-4-5-20251001")

    for groups <- [%{}, %{"ephemeral_5m_input_tokens" => 4000}, "invalid"] do
      changed = %{sample | body: put_in(sample.body, ["usage", "cache_creation"], groups)}
      assert Samples.reference(changed)["status"] == "unknown"
      assert Samples.buffered(changed).usage.pricing.status == :unknown
    end
  end

  @tag billing_case: "basic_usage", billing_layer: "adversarial"
  test "a malformed later counter cannot keep an earlier stream price" do
    model = ReqLLM.model!("openai:gpt-6-luna")
    initial = ReqLLM.Usage.normalize(%{input_tokens: 100, output_tokens: 10})
    incoming = ReqLLM.Usage.normalize(%{input_tokens: false, output_tokens: 12})
    merged = ReqLLM.Usage.merge(initial, incoming)
    context = %{api: "responses", service_tier: "default", regional_processing: false}

    assert ReqLLM.Usage.Cost.apply(merged, model, pricing_context: context).pricing.status ==
             :unknown
  end
end
