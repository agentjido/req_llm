defmodule ReqLLM.Compatibility.ProviderDriftTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Compatibility.{Evidence, ProviderDrift}

  setup do
    config = ProviderDrift.load_config!()
    %{config: config}
  end

  test "loads a bounded anchor matrix backed by checked-in evidence", %{config: config} do
    assert config["schema_version"] == 1
    assert length(config["anchors"]) == 4
    assert config["limits"]["max_concurrency"] == 1
    assert config["limits"]["max_output_tokens_per_anchor"] == 64

    estimated = Enum.sum(Enum.map(config["anchors"], & &1["estimated_max_cost_usd"]))
    assert estimated <= config["limits"]["estimated_max_cost_usd"]
  end

  test "rejects anchors whose expected surface is not in compatibility evidence", %{
    config: config
  } do
    anchors =
      List.update_at(config["anchors"], 0, &Map.put(&1, "surface", "anthropic.unknown"))

    invalid = Map.put(config, "anchors", anchors)

    assert_raise ArgumentError, ~r/surface is not present/, fn ->
      ProviderDrift.validate_config!(invalid, Evidence.load!())
    end
  end

  test "rejects anchor cost estimates above the configured maximum", %{config: config} do
    limits = Map.put(config["limits"], "estimated_max_cost_usd", 0.001)
    invalid = Map.put(config, "limits", limits)

    assert_raise ArgumentError, ~r/estimated cost/, fn ->
      ProviderDrift.validate_config!(invalid, Evidence.load!())
    end
  end

  test "skips unavailable credentials without executing anchors", %{config: config} do
    executor = fn _anchor, _context -> flunk("executor should not run") end

    results =
      ProviderDrift.run(config, executor,
        env: %{},
        checked_at: ~U[2026-07-16 12:00:00Z]
      )

    assert Enum.all?(results, &(&1["status"] == "skipped"))
    assert Enum.all?(results, &is_nil(&1["failure_layer"]))
    assert Enum.all?(results, &(&1["missing_credentials"] != []))
  end

  test "dry runs validate every anchor without credentials or requests", %{config: config} do
    results =
      ProviderDrift.run(config, fn _anchor, _context -> flunk("executor should not run") end,
        env: %{},
        dry_run: true,
        checked_at: ~U[2026-07-16 12:00:00Z]
      )

    assert Enum.all?(results, &(&1["status"] == "planned"))
  end

  test "completed probes produce schema-compatible live evidence", %{config: config} do
    env = credential_env(config)

    executor = fn anchor, _context ->
      %{
        "status" => "pass",
        "surface" => anchor["expected_surface"],
        "fixtures" => [anchor["scenario"]],
        "failure_layer" => nil
      }
    end

    results =
      ProviderDrift.run(config, executor,
        env: env,
        checked_at: ~U[2026-07-16 12:00:00Z],
        correlation: %{"run_id" => "42", "run_attempt" => "2"}
      )

    report =
      ProviderDrift.report(config, results,
        checked_at: ~U[2026-07-16 12:00:00Z],
        correlation: %{"run_id" => "42", "run_attempt" => "2"}
      )

    assert report["summary"] == %{
             "total" => 4,
             "pass" => 4,
             "fail" => 0,
             "skipped" => 0,
             "planned" => 0,
             "estimated_max_cost_usd" => 0.025
           }

    assert report["evidence"]["schema_version"] == Evidence.schema_version()

    assert get_in(report, [
             "evidence",
             "models",
             "openai:gpt-4o-mini",
             "surfaces",
             "openai.responses",
             "scenarios",
             "basic",
             "observations",
             Access.at(0),
             "mode"
           ]) == "live_probe"

    assert Enum.all?(results, &String.starts_with?(&1["correlation_id"], "42-2-"))
  end

  test "a changed execution surface is a provider drift failure", %{config: config} do
    [openai_anchor] = Enum.filter(config["anchors"], &(&1["id"] == "openai-responses-basic"))

    scoped = Map.put(config, "anchors", [openai_anchor])
    scoped = put_in(scoped["limits"]["max_anchors"], 1)

    results =
      ProviderDrift.run(
        scoped,
        fn _anchor, _context ->
          %{
            "status" => "pass",
            "surface" => "openai.chat_completions",
            "fixtures" => ["basic"]
          }
        end,
        env: %{"OPENAI_API_KEY" => "available"},
        checked_at: ~U[2026-07-16 12:00:00Z]
      )

    assert [%{"status" => "fail", "failure_layer" => "provider_drift"} = result] = results
    assert result["remediation"] =~ "Observed surface changed"
  end

  test "reports contain sanitized metadata rather than provider payloads", %{config: config} do
    results =
      ProviderDrift.run(config, fn _anchor, _context -> flunk("executor should not run") end,
        env: %{},
        checked_at: ~U[2026-07-16 12:00:00Z]
      )

    report = ProviderDrift.report(config, results, checked_at: ~U[2026-07-16 12:00:00Z])
    encoded = Jason.encode!(report)

    refute encoded =~ "prompt"
    refute encoded =~ "response_body"
    refute encoded =~ "api_key"
    assert ProviderDrift.markdown(report) =~ "Configure repository secret(s)"
  end

  defp credential_env(config) do
    config["anchors"]
    |> Enum.flat_map(& &1["credential_env"])
    |> Enum.uniq()
    |> Map.new(&{&1, "available"})
  end
end
