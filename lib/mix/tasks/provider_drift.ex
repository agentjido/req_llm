defmodule Mix.Tasks.ReqLlm.ProviderDrift do
  @shortdoc "Run bounded live provider drift verification"
  @moduledoc """
  Run a small, credential-aware live verification matrix without updating
  fixtures or checked-in compatibility evidence.

      mix req_llm.provider_drift --dry-run
      mix req_llm.provider_drift --provider openai
      mix req_llm.provider_drift --output-dir .artifacts/provider-drift

  Missing provider credentials are reported as skipped anchors. The generated
  JSON embeds compatibility evidence using the current versioned schema, while
  the Markdown report contains only model, surface, scenario, status, failure
  layer, remediation, and correlation metadata.

  Fixture recording remains a separate explicit action through
  `mix req_llm.model_compat MODEL --scenario SCENARIO --record`.
  """

  use Mix.Task

  alias Mix.Tasks.ReqLlm.ModelCompat
  alias ReqLLM.Compatibility.{Evidence, ProviderDrift}

  @preferred_cli_env :test

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)
    opts = parse_args!(args)
    config = ProviderDrift.load_config!(opts[:config] || ProviderDrift.default_config_path())
    providers = providers(opts[:provider])
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)
    correlation = correlation()

    results =
      ProviderDrift.run(config, &execute_anchor/2,
        providers: providers,
        dry_run: opts[:dry_run] || false,
        checked_at: checked_at,
        correlation: correlation
      )

    if results == [] do
      Mix.raise("No provider drift anchors match --provider #{opts[:provider]}")
    end

    report =
      ProviderDrift.report(config, results,
        checked_at: checked_at,
        correlation: correlation,
        dry_run: opts[:dry_run] || false
      )

    output_dir = Path.expand(opts[:output_dir] || "_build/provider_drift")
    json_path = Path.join(output_dir, "provider-drift-report.json")
    markdown_path = Path.join(output_dir, "provider-drift-report.md")
    ProviderDrift.write_report!(json_path, markdown_path, report)

    summary = ProviderDrift.markdown(report)
    Mix.shell().info(summary)
    Mix.shell().info("Reports: #{json_path}, #{markdown_path}")
    append_github_summary(summary)

    if ProviderDrift.failures?(results) do
      failed = Enum.count(results, &(&1["status"] == "fail"))
      Mix.raise("#{failed} provider drift anchor(s) failed; inspect the sanitized report")
    end
  end

  @doc false
  def execute_anchor(anchor, context) do
    stage_root = stage_root(anchor)
    File.rm_rf(stage_root)

    try do
      provider = String.to_existing_atom(anchor["provider"])
      operation = String.to_existing_atom(anchor["operation"])
      scenario = anchor["scenario"]
      args = ModelCompat.test_args_for(provider, operation, scenario)

      {output, exit_code} =
        System.cmd("mix", args,
          env: probe_env(anchor, stage_root, context),
          stderr_to_stdout: true
        )

      parsed =
        ModelCompat.parse_test_result(
          provider,
          anchor["model"],
          output,
          exit_code,
          scenario
        )

      fixtures = fixture_names(stage_root, parsed.fixtures)

      surface =
        Evidence.fixture_surface(
          stage_root,
          anchor["model_spec"],
          operation,
          fixtures
        )

      probe_result(parsed, fixtures, surface)
    after
      File.rm_rf(stage_root)
    end
  end

  defp parse_args!(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          output_dir: :string,
          provider: :string,
          dry_run: :boolean
        ]
      )

    if positional != [] or invalid != [] do
      Mix.raise("Invalid provider drift arguments: #{inspect(positional ++ invalid)}")
    end

    opts
  end

  defp providers(nil), do: ["all"]

  defp providers(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["all"]
      selected -> selected
    end
  end

  defp probe_env(anchor, stage_root, context) do
    correlation = context.correlation

    [
      {"REQ_LLM_MODELS", anchor["model_spec"]},
      {"REQ_LLM_OPERATION", anchor["operation"]},
      {"REQ_LLM_FIXTURES_MODE", "record"},
      {"REQ_LLM_DEBUG", "1"},
      {"REQ_LLM_INCLUDE_RESPONSES", "1"},
      {"REQ_LLM_FIXTURE_ALLOW_CREDENTIAL_FALLBACK", "0"},
      {"REQ_LLM_FIXTURE_RECORD_ROOT", stage_root},
      {"REQ_LLM_DRIFT_MAX_TOKENS", Integer.to_string(anchor["max_output_tokens"])},
      {"REQ_LLM_DRIFT_CORRELATION_ID", correlation_id(correlation, anchor["id"])}
    ]
  end

  defp stage_root(anchor) do
    suffix =
      [
        anchor["provider"],
        anchor["model"],
        anchor["scenario"],
        System.unique_integer([:positive])
      ]
      |> Enum.map_join("_", &path_slug/1)

    Path.join(System.tmp_dir!(), "req_llm_provider_drift_#{suffix}")
  end

  defp path_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp fixture_names(stage_root, parsed_fixtures) do
    staged =
      stage_root
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))

    (parsed_fixtures ++ staged)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp probe_result(%{status: :pass}, fixtures, nil) do
    %{
      "status" => "fail",
      "fixtures" => fixtures,
      "surface" => nil,
      "failure_layer" => "materialization",
      "remediation" => "No staged fixture surface was available for the successful probe"
    }
  end

  defp probe_result(%{status: :pass}, fixtures, surface) do
    %{
      "status" => "pass",
      "fixtures" => fixtures,
      "surface" => surface,
      "failure_layer" => nil
    }
  end

  defp probe_result(parsed, fixtures, surface) do
    %{
      "status" => "fail",
      "fixtures" => fixtures,
      "surface" => surface,
      "failure_layer" => parsed.failure_layer || "assertion"
    }
  end

  defp correlation do
    %{
      "workflow" => env_or("GITHUB_WORKFLOW", "local"),
      "run_id" => env_or("GITHUB_RUN_ID", "local"),
      "run_attempt" => env_or("GITHUB_RUN_ATTEMPT", "1"),
      "sha" => env_or("GITHUB_SHA", git_sha())
    }
  end

  defp correlation_id(correlation, anchor_id) do
    "#{correlation["run_id"]}-#{correlation["run_attempt"]}-#{anchor_id}"
  end

  defp env_or(name, fallback) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _value -> fallback
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _result -> "unknown"
    end
  end

  defp append_github_summary(summary) do
    case System.get_env("GITHUB_STEP_SUMMARY") do
      path when is_binary(path) and path != "" -> File.write!(path, summary, [:append])
      _value -> :ok
    end
  end
end
