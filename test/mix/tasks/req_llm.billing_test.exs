defmodule Mix.Tasks.ReqLlm.BillingTest do
  use ExUnit.Case, async: true
  alias ReqLLM.Test.Billing.{Cases, CLI}

  test "listing and default checking remain offline" do
    assert CLI.parse!([]).command == "check"
    assert CLI.parse!(["list"]).command == "list"
    {args, env} = CLI.command(CLI.parse!(["check"]), "/tmp/billing-check")
    assert Enum.take(args, 2) == ["test", "test/req_llm/billing"]
    assert {"REQ_LLM_FIXTURES_MODE", "replay"} in env
    assert {"REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK", "0"} in env
  end

  test "one-hour cases cannot use a generic five-minute catalog rate" do
    generic = %{components: [%{id: "token.cache_write", rate: 0.125}]}

    assert_raise ArgumentError, ~r/duration-specific/, fn ->
      CLI.require_case_rates!("cache_1h", generic)
    end

    assert_raise ArgumentError, fn -> CLI.require_case_rates!("mixed_cache_ttl", generic) end

    specific = %{
      components: [
        %{id: "token.cache_write.1h", rate: 0.20, applies_when: %{"cache_ttl" => "1h"}}
      ]
    }

    assert :ok == CLI.require_case_rates!("cache_1h", specific)
    assert :ok == CLI.require_case_rates!("basic_usage", generic)
  end

  test "a layer filter uses one ExUnit include expression" do
    {args, _env} = CLI.command(CLI.parse!(["check", "--layer", "pricing"]), "/tmp/billing-check")
    assert Enum.count(args, &(&1 == "--only")) == 1
    assert "billing_layer:pricing" in args
  end

  test "released Haiku 5.5 catalog permits one-hour and mixed recording" do
    model = ReqLLM.model!("anthropic:claude-haiku-5-5")
    assert :ok == CLI.require_case_rates!("cache_1h", model.pricing)
    assert :ok == CLI.require_case_rates!("mixed_cache_ttl", model.pricing)
  end

  test "audit selects saved capture tests in an offline child" do
    config =
      CLI.parse!([
        "audit",
        "--run",
        "/tmp/billing-audit",
        "--case",
        "basic_usage",
        "--layer",
        "pipeline"
      ])

    {args, env} = CLI.command(config, "/tmp/billing-audit")
    assert "test/req_llm/billing/run_audit_test.exs" in args
    assert "billing_layer:pipeline" in args
    assert {"REQ_LLM_BILLING_MODE", "audit"} in env
    assert {"REQ_LLM_BILLING_CASES", "basic_usage"} in env
    assert {"REQ_LLM_FIXTURES_MODE", "replay"} in env
  end

  test "selectors reject unsupported providers and invalid transport modes" do
    assert_raise ArgumentError, fn -> Cases.select(["mixed_cache_ttl"], ["openai:gpt-6-luna"]) end
    assert_raise ArgumentError, fn -> Cases.select(["compact_unknown"], ["openai:gpt-6-luna"]) end

    assert_raise ArgumentError, fn ->
      Cases.select(["basic_usage"], ["openai:gpt-6-luna"], "invalid")
    end
  end

  test "artifact actions require exact inputs" do
    assert_raise ArgumentError, fn -> CLI.parse!(["audit"]) end
    assert_raise ArgumentError, fn -> CLI.parse!(["promote", "--run", "/tmp/example"]) end
    assert_raise ArgumentError, fn -> CLI.parse!(["check", "--unknown-option"]) end

    assert_raise ArgumentError, fn ->
      CLI.parse!([
        "promote",
        "--run",
        "/tmp/example",
        "--case",
        "basic_usage",
        "--model",
        "openai:gpt-6-luna"
      ])
    end

    assert_raise ArgumentError, fn ->
      CLI.parse!(["check", "--provider", "anthropic", "--model", "openai:gpt-6-luna"])
    end
  end
end
