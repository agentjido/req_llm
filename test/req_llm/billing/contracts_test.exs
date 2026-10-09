defmodule ReqLLM.Billing.ContractsTest do
  use ExUnit.Case, async: false
  alias ReqLLM.Test.Billing.{Audit, Capture, CLI, Money, Reference, Run, Samples}
  @moduletag :billing
  @moduletag billing_layer: "capture"

  setup do
    ReqLLM.Test.Env.isolate!(~w(REQ_LLM_BILLING_RUN REQ_LLM_FIXTURE_REPLAY_ROOT))
    dir = Path.join(System.tmp_dir!(), "billing_contract_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "reference money uses explicit half-up microdollar rounding" do
    assert Money.micros("0.50", 10, 1_000_000, "0.5") == 3
    assert Money.usd(3) == "0.000003"
    assert_raise ArgumentError, fn -> Money.fraction("NaN") end
  end

  test "estimates measure complete JSON rather than the context display" do
    selection = %{"model" => "openai:gpt-6-luna", "case_id" => "long_context"}
    context = ReqLLM.Context.new([ReqLLM.Context.user(String.duplicate("x", 100_000))])
    assert ReqLLM.Test.Billing.Live.estimate(selection, context) >= 55_000
  end

  test "a reported estimate overrun halts all later requests", %{dir: dir} do
    Run.create!(dir, [], origin: "synthetic", budget_micros: 100, max_requests: 4)

    attempt =
      Run.reserve!(
        dir,
        %{case_id: "basic_usage", model: "openai:gpt-6-luna", mode: "buffered"},
        10
      )

    assert_raise ArgumentError, fn -> Run.reconcile!(dir, attempt["attempt_id"], 11) end
    assert_raise ArgumentError, fn -> Run.reserve!(dir, %{}, 1) end
    assert Run.load!(dir)["halted"]
  end

  test "reference comparisons accept equivalent per-call and per-thousand rates" do
    sample = Samples.sample("hosted_web_search", "openai:gpt-6-luna")
    reference = Samples.reference(sample)
    observed = Samples.buffered(sample).usage |> Run.stringify()
    assert Audit.compare(reference, observed)["status"] == "passed"

    changed =
      update_in(observed, ["cost", "line_items"], fn items ->
        Enum.map(items, fn item ->
          if String.starts_with?(item["id"], "tool.web_search"),
            do: Map.merge(item, %{"per" => 1000, "rate" => item["rate"] / item["per"] * 1000}),
            else: item
        end)
      end)

    assert Audit.compare(reference, changed)["status"] == "passed"
  end

  test "buffered capture saves error bodies before library decoding", %{dir: dir} do
    Run.create!(dir, [], origin: "synthetic", budget_micros: 100, max_requests: 1)

    attempt =
      Run.reserve!(
        dir,
        %{case_id: "basic_usage", model: "openai:gpt-6-luna", mode: "buffered"},
        0
      )

    System.put_env("REQ_LLM_BILLING_RUN", dir)
    model = ReqLLM.model!(attempt["model"])
    path = Path.join(dir, "transcripts/#{attempt["fixture"]}.json")

    request = %Req.Request{
      url: URI.parse("https://api.openai.com/v1/responses"),
      private: %{
        req_llm_model: model,
        llm_fixture_path: path,
        llm_canonical_json: %{"model" => model.id}
      },
      headers: %{"authorization" => ["Bearer private-test-secret"]}
    }

    raw = %{"error" => %{"type" => "authentication_error", "message" => "invalid key"}}
    response = %Req.Response{status: 401, body: Jason.encode!(raw)}
    assert {^request, ^response} = Capture.buffered_response({request, response})
    assert Run.attempt!(dir, attempt["attempt_id"])["capture_complete"]
    rows = Run.records(dir, "raw.jsonl")
    assert Enum.find(rows, &(&1["kind"] == "response"))["body"] == raw
    refute File.read!(path) =~ "private-test-secret"
  end

  test "Responses tool cap is included in the common buffered and stream encoder" do
    context = ReqLLM.Context.new([ReqLLM.Context.user("Search once.")])

    body =
      ReqLLM.Providers.OpenAI.ResponsesAPI.build_request_body(
        context,
        "gpt-6-luna",
        [provider_options: [openai_max_tool_calls: 1]],
        nil
      )

    assert body["max_tool_calls"] == 1
  end

  test "record requires exact selections and explicit request limits" do
    for args <- [
          ["record"],
          ["record", "--case", "basic_usage"],
          ["check", "--unknown"],
          ["check", "--case", "not_a_case"]
        ] do
      assert_raise ArgumentError, fn -> CLI.parse!(args) end
    end
  end

  test "offline child ignores ambient record mode and disables credential fallback", %{dir: dir} do
    config = CLI.parse!(["check", "--case", "mixed_cache_ttl"])
    {args, env} = CLI.command(config, dir)
    assert "test/req_llm/billing" in args
    assert env |> Map.new() |> Map.fetch!("REQ_LLM_FIXTURES_MODE") == "replay"
    assert env |> Map.new() |> Map.fetch!("REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK") == "0"
  end

  test "run limits retain earlier evidence and reject an exhausted reservation", %{dir: dir} do
    Run.create!(dir, [], origin: "synthetic", budget_micros: 100, max_requests: 1)

    attempt =
      Run.reserve!(
        dir,
        %{case_id: "basic_usage", model: "openai:gpt-6-luna", mode: "buffered"},
        100
      )

    Run.append!(dir, "raw.jsonl", attempt, %{
      "kind" => "request",
      "body" => %{"api_key" => "secret", "input_tokens" => false}
    })

    assert_raise ArgumentError, fn -> Run.reserve!(dir, %{}, 1) end
    [row] = Run.records(dir, "raw.jsonl")
    assert row["body"]["api_key"] == "[REDACTED]"
    assert row["body"]["input_tokens"] == false
    assert_raise ArgumentError, fn -> Run.create!(dir, []) end
  end

  test "gateway credentials are redacted inside provider error strings" do
    ReqLLM.Test.Env.isolate!(["OPENROUTER_API_KEY"])
    System.put_env("OPENROUTER_API_KEY", "private-router-test-secret")
    assert Run.redact("Invalid key private-router-test-secret") == "Invalid key [REDACTED]"
  end

  test "promotion rechecks current observations and freezes one independent calculation", %{
    dir: dir
  } do
    Run.create!(dir, [], origin: "live", budget_micros: 100, max_requests: 1)
    sample = Samples.sample("basic_usage", "openai:gpt-6-luna")

    attempt =
      Run.reserve!(
        dir,
        %{case_id: sample.case_id, model: sample.model, mode: "buffered", phase: "cold"},
        100
      )

    path = Path.join(dir, "transcripts/#{attempt["fixture"]}.json")
    transcript = Samples.transcript(sample)
    ReqLLM.Test.Transcript.write!(transcript, path)
    Capture.export!(dir, attempt, path, transcript)
    Run.update_attempt!(dir, attempt["attempt_id"], %{"state" => "complete"})

    Run.append!(dir, "observed.jsonl", attempt, %{
      "kind" => "usage",
      "usage" => Samples.buffered(sample).usage
    })

    [target] = Audit.promote!(dir, [sample.case_id], Path.join(dir, "promoted"))
    metadata = File.read!(target <> ".billing.json") |> Jason.decode!()
    assert metadata["calculation"] == Samples.reference(sample)
    assert Map.keys(metadata["rate_book"]["models"]) == [sample.model]
    assert metadata["source"]["run_id"] == Path.basename(dir)
    refute Map.has_key?(metadata["attempt"], "request")

    assert_raise ArgumentError, fn ->
      Audit.promote!(dir, [sample.case_id], Path.join(dir, "promoted"))
    end

    [observation] = Run.records(dir, "observed.jsonl")
    changed = put_in(observation, ["usage", "total_cost"], 1.00)
    File.write!(Path.join(dir, "observed.jsonl"), Jason.encode!(changed) <> "\n")

    assert_raise ArgumentError, fn ->
      Audit.promote!(dir, [sample.case_id], Path.join(dir, "other"))
    end
  end

  test "capture exports raw fields and audit calculates an independent worksheet", %{dir: dir} do
    Run.create!(dir, [], origin: "synthetic", budget_micros: 100, max_requests: 1)
    sample = Samples.sample("mixed_cache_ttl", "anthropic:claude-haiku-4-5-20251001")

    attempt =
      Run.reserve!(dir, %{case_id: sample.case_id, model: sample.model, mode: "buffered"}, 0)

    path = Path.join(dir, "transcripts/#{attempt["fixture"]}.json")
    transcript = Samples.transcript(sample)
    ReqLLM.Test.Transcript.write!(transcript, path)
    Capture.export!(dir, attempt, path, transcript)
    usage = Samples.buffered(sample).usage
    Run.append!(dir, "observed.jsonl", attempt, %{"kind" => "usage", "usage" => usage})
    assert [%{"status" => "passed"}] = Audit.check!(dir)
    [calculation] = Run.records(dir, "billing.jsonl")
    assert calculation["total"] == "0.017150"

    assert Enum.any?(
             calculation["line_items"],
             &(&1["meter"] == "cache_1h" and &1["quantity"] == 6000)
           )

    assert_raise ArgumentError, fn -> Audit.promote!(dir, [sample.case_id]) end
  end

  test "missing capture dates are not exported as a fresh live call", %{dir: dir} do
    Run.create!(dir, [], origin: "live", budget_micros: 100, max_requests: 1)
    sample = Samples.sample("basic_usage", "openai:gpt-6-luna")

    attempt =
      Run.reserve!(dir, %{case_id: sample.case_id, model: sample.model, mode: "buffered"}, 0)

    raw =
      sample
      |> Samples.transcript()
      |> ReqLLM.Test.Transcript.to_map()
      |> Map.delete("captured_at")

    path = Path.join(dir, "transcripts/#{attempt["fixture"]}.json")
    File.write!(path, Jason.encode!(raw))
    transcript = ReqLLM.Test.Transcript.read!(path)
    assert transcript.captured_at == nil
    Capture.export!(dir, attempt, path, transcript)
    assert Run.attempt!(dir, attempt["attempt_id"])["capture_origin"] == "legacy"
  end

  test "incomplete attempts and source tampering cannot pass audit", %{dir: dir} do
    Run.create!(dir, [], origin: "synthetic", budget_micros: 100, max_requests: 1)
    Run.reserve!(dir, %{case_id: "basic_usage", model: "openai:gpt-6-luna", mode: "streamed"}, 0)
    assert [%{"status" => "blocked"}] = Audit.check!(dir)
    assert File.exists?(Path.join(dir, "summary.md"))
    assert_raise ArgumentError, fn -> Audit.safe_path!(dir, "../outside.json") end
  end

  test "stream parsing joins payload fragments before interpreting provider usage" do
    sample = Samples.sample("returned_service_tier", "openai:gpt-6-luna")
    raw = sample |> Samples.transcript(true) |> ReqLLM.Test.Transcript.to_map()
    joined = raw["chunks"] |> Enum.map(&Base.decode64!(&1["b64"])) |> IO.iodata_to_binary()
    split = for <<byte <- joined>>, do: %{"b64" => Base.encode64(<<byte>>)}
    assert Reference.response_body(Map.put(raw, "chunks", split)) == sample.body
  end
end
