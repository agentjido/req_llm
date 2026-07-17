defmodule Mix.Tasks.ReqLlm.ProviderDriftTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReqLlm.ProviderDrift
  alias ReqLLM.Test.Helpers

  setup do
    previous_limit = System.get_env("REQ_LLM_DRIFT_MAX_TOKENS")

    on_exit(fn ->
      restore_env("REQ_LLM_DRIFT_MAX_TOKENS", previous_limit)
      Mix.Task.reenable("req_llm.provider_drift")
    end)

    :ok
  end

  test "dry run writes deterministic sanitized reports" do
    output_dir =
      Path.join(System.tmp_dir!(), "provider_drift_task_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(output_dir) end)

    output =
      capture_io(fn ->
        ProviderDrift.run(["--dry-run", "--output-dir", output_dir])
      end)

    report =
      output_dir
      |> Path.join("provider-drift-report.json")
      |> File.read!()
      |> Jason.decode!()

    assert output =~ "4 planned"
    assert report["mode"] == "dry_run"
    assert report["summary"]["planned"] == 4
    assert File.exists?(Path.join(output_dir, "provider-drift-report.md"))
    refute Jason.encode!(report) =~ "response_body"
  end

  test "provider selection is explicit and rejects unknown values" do
    output_dir =
      Path.join(System.tmp_dir!(), "provider_drift_empty_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(output_dir) end)

    assert_raise Mix.Error, ~r/No provider drift anchors match/, fn ->
      capture_io(fn ->
        ProviderDrift.run([
          "--dry-run",
          "--provider",
          "unknown",
          "--output-dir",
          output_dir
        ])
      end)
    end
  end

  test "drift token cap is opt-in and never increases a scenario budget" do
    System.put_env("REQ_LLM_DRIFT_MAX_TOKENS", "32")

    assert Helpers.fixture_opts("basic", max_tokens: 50)[:max_tokens] == 32
    assert Helpers.fixture_opts("basic", max_tokens: 16)[:max_tokens] == 16

    System.delete_env("REQ_LLM_DRIFT_MAX_TOKENS")
    assert Helpers.fixture_opts("basic", max_tokens: 50)[:max_tokens] == 50
  end

  test "workflow is scheduled and manual without pull-request secrets or write permissions" do
    workflow = File.read!(".github/workflows/provider-drift.yml")

    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "schedule:"
    assert workflow =~ "contents: read"
    assert workflow =~ "timeout-minutes: 15"
    refute workflow =~ "pull_request:"
    refute workflow =~ "contents: write"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
