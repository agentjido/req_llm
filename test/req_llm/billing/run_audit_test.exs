defmodule ReqLLM.Billing.RunAuditTest do
  use ExUnit.Case, async: false
  @moduletag :billing

  if System.get_env("REQ_LLM_BILLING_MODE") == "audit" do
    alias ReqLLM.Test.Billing.{Audit, Reference, Run, Samples}
    dir = System.fetch_env!("REQ_LLM_BILLING_RUN")

    for attempt <- Run.load!(dir)["attempts"],
        Samples.selected?(%{case_id: attempt["case_id"], model: attempt["model"]}),
        System.get_env("REQ_LLM_BILLING_STREAM_MODE") in [nil, "", "both", attempt["mode"]] do
      @tag billing_case: attempt["case_id"], billing_layer: "capture", model: attempt["model"]
      test "#{attempt["attempt_id"]}: source capture integrity" do
        dir = System.fetch_env!("REQ_LLM_BILLING_RUN")
        attempt = unquote(Macro.escape(attempt))
        assert attempt["capture_complete"] == true

        assert Run.hash(Audit.safe_path!(dir, attempt["transcript"])) ==
                 attempt["transcript_sha256"]
      end

      @tag billing_case: attempt["case_id"], billing_layer: "pricing", model: attempt["model"]
      test "#{attempt["attempt_id"]}: frozen independent rates match recorded pricing" do
        dir = System.fetch_env!("REQ_LLM_BILLING_RUN")
        attempt = unquote(Macro.escape(attempt))
        assert Audit.check_attempt!(dir, attempt)["status"] == "passed"
        sample = sample(attempt)

        reference =
          Reference.calculate(
            sample.model,
            sample.body,
            sample.request,
            Run.load!(dir)["rate_book"]
          )

        current = Samples.buffered(sample).usage |> Run.stringify()
        assert Audit.compare(reference, current)["status"] == "passed"
      end

      @tag billing_case: attempt["case_id"],
           billing_layer: "normalization",
           model: attempt["model"]
      test "#{attempt["attempt_id"]}: raw token counters match current decoding" do
        sample = sample(unquote(Macro.escape(attempt)))
        response = Samples.buffered(sample)
        usage = sample.body["usage"]

        if is_map(usage) do
          input = usage["input_tokens"] || usage["prompt_tokens"]
          output = usage["output_tokens"] || usage["completion_tokens"]
          assert response.usage.input_tokens == input
          assert response.usage.output_tokens == output
        end
      end

      @tag billing_case: attempt["case_id"], billing_layer: "adversarial", model: attempt["model"]
      test "#{attempt["attempt_id"]}: malformed input cannot become a known zero" do
        sample = sample(unquote(Macro.escape(attempt)))
        usage = sample.body["usage"]

        if is_map(usage) do
          key = if Map.has_key?(usage, "prompt_tokens"), do: "prompt_tokens", else: "input_tokens"
          changed = %{sample | body: Map.put(sample.body, "usage", Map.put(usage, key, false))}
          assert Samples.reference(changed)["status"] == "unknown"
          assert Samples.buffered(changed).usage.pricing.status == :unknown
        end
      end

      if attempt["mode"] == "streamed" do
        import ReqLLM.Test.StreamServerHelpers
        @tag billing_case: attempt["case_id"], billing_layer: "pipeline", model: attempt["model"]
        test "#{attempt["attempt_id"]}: raw stream replays through the current server" do
          Process.flag(:trap_exit, true)
          attempt = unquote(Macro.escape(attempt))
          sample = sample(attempt)
          dir = System.fetch_env!("REQ_LLM_BILLING_RUN")
          raw = Audit.safe_path!(dir, attempt["transcript"]) |> File.read!() |> Jason.decode!()
          model = ReqLLM.model!(attempt["model"])
          {:ok, provider} = ReqLLM.provider(model.provider)

          server =
            start_server(
              provider_mod: provider,
              model: model,
              pricing_context: %{api: "chat", inference_geo: "global"}
            )

          mock_http_task(server)
          ReqLLM.StreamServer.set_fixture_context(server, %{url: sample.request["url"]}, %{})

          chunks =
            case raw do
              %{"chunks" => chunks} ->
                Enum.map(chunks, &Base.decode64!(&1["b64"]))

              %{"frames" => frames} ->
                frames
                |> Enum.filter(&(&1["direction"] == "server"))
                |> Enum.map(&"data: #{Jason.encode!(&1["event"])}\n\n")
            end

          Enum.each(chunks, &ReqLLM.StreamServer.http_event(server, {:data, &1}))
          ReqLLM.StreamServer.http_event(server, :done)
          assert {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server, 1000)
          assert metadata.usage[:total_cost] == Samples.buffered(sample).usage[:total_cost]
          ReqLLM.StreamServer.cancel(server)
        end
      end
    end

    defp sample(attempt) do
      dir = System.fetch_env!("REQ_LLM_BILLING_RUN")
      raw = Audit.safe_path!(dir, attempt["transcript"]) |> File.read!() |> Jason.decode!()
      base = Samples.sample(attempt["case_id"], attempt["model"])
      %{base | body: Reference.response_body(raw), request: %{"url" => raw["request"]["url"]}}
    end
  else
    @tag billing_layer: "capture"
    test "run audit requires its explicit artifact context" do
      assert System.get_env("REQ_LLM_BILLING_MODE") != "audit"
    end
  end
end
