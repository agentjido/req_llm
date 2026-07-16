defmodule Mix.Tasks.ReqLlm.ModelSupportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReqLlm.ModelSupport

  test "targets the checked-in evidence and reference artifacts" do
    assert ModelSupport.evidence_path() == Path.expand("priv/model_compat_scenarios.json")
    assert ModelSupport.reference_path() == Path.expand("guides/model-support.md")
    assert File.exists?(ReqLLM.Compatibility.Evidence.default_path())
  end

  test "checks the deterministic evidence and reference artifacts" do
    Mix.Task.reenable("req_llm.model_support")

    output = capture_io(fn -> ModelSupport.run(["--check"]) end)

    assert output =~ "Compatibility evidence and support reference are current"
  end

  test "refreshes catalog declarations and fixture-backed surfaces before checking" do
    evidence = ReqLLM.Compatibility.Evidence.load!(ModelSupport.evidence_path())

    stale =
      evidence
      |> put_in(
        ["models", "openai:gpt-4o-mini", "catalog_status"],
        "missing"
      )
      |> put_in(
        ["models", "openai:gpt-4o-mini", "surfaces", "openai.responses", "declaration"],
        "unknown"
      )

    refreshed = ModelSupport.refresh_evidence(stale)

    assert get_in(refreshed, ["models", "openai:gpt-4o-mini", "catalog_status"]) == "present"

    assert get_in(refreshed, [
             "models",
             "openai:gpt-4o-mini",
             "surfaces",
             "openai.responses",
             "declaration"
           ]) == "declared"
  end

  test "prints evidence-backed model surface status without changing resolution" do
    Mix.Task.reenable("req_llm.model_support")
    before_resolution = ReqLLM.model("openai:gpt-4o-mini")

    output =
      capture_io(fn ->
        ModelSupport.run(["--model", "openai:gpt-4o-mini"])
      end)

    assert output =~ "openai:gpt-4o-mini"
    assert output =~ "openai.responses"
    assert ReqLLM.model("openai:gpt-4o-mini") == before_resolution
  end

  test "rejects invalid options" do
    Mix.Task.reenable("req_llm.model_support")

    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      ModelSupport.run(["--unknown"])
    end
  end
end
