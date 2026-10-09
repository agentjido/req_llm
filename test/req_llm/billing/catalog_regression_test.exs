defmodule ReqLLM.Billing.CatalogRegressionTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.Test.Billing.{Audit, Reference, Run, Samples}

  @moduletag :billing
  @model "anthropic:claude-haiku-5-5"
  @evidence_path Path.expand(
                   "../../support/billing/regressions/anthropic_haiku_5_5_mixed_ttl.json",
                   __DIR__
                 )
  @external_resource @evidence_path

  evidence = @evidence_path |> File.read!() |> Jason.decode!()

  if Samples.selected?(%{case_id: "mixed_cache_ttl", model: @model}) do
    for attempt <- evidence["attempts"] do
      @tag billing_case: "mixed_cache_ttl", billing_layer: "pricing", model: @model
      test "failed #{attempt["mode"]} Haiku 5.5 capture has the corrected catalog price" do
        attempt = unquote(Macro.escape(attempt))
        sample = sample(attempt)

        reference =
          Reference.calculate(@model, sample.body, sample.request, evidence()["rate_book"])

        assert attempt["original_state"] == "failed"
        assert attempt["original_observed_total_cost"] == "0.008261"
        assert reference == attempt["calculation"]
        assert reference["total"] == "0.010739"

        response = Samples.buffered(sample)
        normalized = ReqLLM.Usage.normalize(response.usage)
        assert normalized.cache_write_tokens_by_ttl == %{"5m" => 33_031, "1h" => 33_034}
        assert Audit.compare(reference, Run.stringify(response.usage))["status"] == "passed"
      end

      if attempt["mode"] == "streamed" do
        @tag billing_case: "mixed_cache_ttl", billing_layer: "pipeline", model: @model
        test "saved Haiku 5.5 stream chunks use the released duration tariffs" do
          Process.flag(:trap_exit, true)
          attempt = unquote(Macro.escape(attempt))
          sample = sample(attempt)

          reference =
            Reference.calculate(@model, sample.body, sample.request, evidence()["rate_book"])

          server =
            start_server(
              provider_mod: ReqLLM.Providers.Anthropic,
              model: ReqLLM.model!(@model),
              pricing_context: %{api: "chat", inference_geo: "global"}
            )

          mock_http_task(server)
          ReqLLM.StreamServer.set_fixture_context(server, %{url: sample.request["url"]}, %{})

          Enum.each(attempt["raw"]["chunks"], fn chunk ->
            ReqLLM.StreamServer.http_event(server, {:data, Base.decode64!(chunk["b64"])})
          end)

          ReqLLM.StreamServer.http_event(server, :done)
          assert {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server, 1000)
          assert Audit.compare(reference, Run.stringify(metadata.usage))["status"] == "passed"
          ReqLLM.StreamServer.cancel(server)
        end
      end
    end

    @tag billing_case: "mixed_cache_ttl", billing_layer: "pricing", model: @model
    test "generated prompt boundary variants apply the Haiku multiplier once" do
      base = sample(hd(evidence()["attempts"]))

      for {prompt, expected} <- [{100_000, "0.014132"}, {100_001, "0.070656"}] do
        sample = %{base | body: put_in(base.body, ["usage", "input_tokens"], prompt - 66_065)}

        reference =
          Reference.calculate(@model, sample.body, sample.request, evidence()["rate_book"])

        assert reference["total"] == expected

        current = Samples.buffered(sample).usage |> Run.stringify()
        assert Audit.compare(reference, current)["status"] == "passed"
      end
    end

    defp evidence, do: @evidence_path |> File.read!() |> Jason.decode!()

    defp sample(attempt) do
      base = Samples.sample("mixed_cache_ttl", @model)

      %{
        base
        | body: Reference.response_body(attempt["raw"]),
          request: %{"url" => "https://api.anthropic.com/v1/messages"}
      }
    end
  end
end
