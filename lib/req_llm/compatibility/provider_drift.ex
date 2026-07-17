defmodule ReqLLM.Compatibility.ProviderDrift do
  @moduledoc """
  Bounded, read-only live verification for a small compatibility anchor matrix.

  Provider drift reports are tooling artifacts. They do not update checked-in
  fixtures, compatibility evidence, support tiers, model resolution, or request
  routing.
  """

  alias ReqLLM.Compatibility.{Evidence, ScenarioCatalog}

  @config_schema_version 1
  @report_schema_version 1
  @operations ~w(text embedding image speech transcription rerank ocr)
  @credential_name ~r/^[A-Z][A-Z0-9_]*$/

  @doc "Returns the checked-in anchor configuration path."
  @spec default_config_path() :: Path.t()
  def default_config_path do
    :req_llm
    |> :code.priv_dir()
    |> Path.join("provider_drift_anchors.json")
  end

  @doc "Loads and validates the checked-in anchor configuration."
  @spec load_config!(Path.t(), keyword()) :: map()
  def load_config!(path \\ default_config_path(), opts \\ []) do
    evidence = Keyword.get_lazy(opts, :evidence, &Evidence.load!/0)

    with {:ok, content} <- File.read(path),
         {:ok, config} <- Jason.decode(content) do
      validate_config!(config, evidence)
    else
      {:error, reason} ->
        raise ArgumentError, "cannot load provider drift config: #{inspect(reason)}"
    end
  end

  @doc "Validates anchor selection, evidence references, and resource limits."
  @spec validate_config!(map(), map()) :: map()
  def validate_config!(config, evidence) when is_map(config) and is_map(evidence) do
    require_equal!(config["schema_version"], @config_schema_version, "config schema_version")

    limits = require_map!(config["limits"], "limits")
    anchors = require_non_empty_list!(config["anchors"], "anchors")

    validate_limits!(limits)
    validate_anchor_count!(anchors, limits)
    validate_unique_anchor_ids!(anchors)
    Enum.each(anchors, &validate_anchor!(&1, limits, evidence))
    validate_cost_budget!(anchors, limits)

    config
  end

  @doc "Builds a credential-aware plan without making provider requests."
  @spec plan(map(), keyword()) :: [map()]
  def plan(config, opts \\ []) when is_map(config) do
    env = Keyword.get(opts, :env, System.get_env())
    providers = provider_filter(Keyword.get(opts, :providers, []))
    dry_run? = Keyword.get(opts, :dry_run, false)

    config["anchors"]
    |> Enum.filter(&selected_provider?(&1, providers))
    |> Enum.map(&plan_anchor(&1, env, dry_run?))
  end

  @doc "Runs ready anchors through the supplied bounded executor."
  @spec run(map(), (map(), map() -> map()), keyword()) :: [map()]
  def run(config, executor, opts \\ []) when is_map(config) and is_function(executor, 2) do
    checked_at = Keyword.get(opts, :checked_at, DateTime.utc_now()) |> DateTime.truncate(:second)
    correlation = Keyword.get(opts, :correlation, %{})
    plans = plan(config, opts)
    limits = config["limits"]

    ready = Enum.filter(plans, &(&1["status"] == "ready"))

    executed =
      ready
      |> Task.async_stream(
        fn anchor ->
          started_at = System.monotonic_time(:millisecond)

          result =
            executor.(anchor, %{
              checked_at: checked_at,
              correlation: correlation,
              limits: limits
            })

          duration_ms = System.monotonic_time(:millisecond) - started_at
          normalize_execution_result(anchor, result, checked_at, correlation, duration_ms)
        end,
        max_concurrency: limits["max_concurrency"],
        timeout: limits["timeout_seconds"] * 1_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(ready)
      |> Map.new(fn
        {{:ok, result}, _anchor} ->
          {result["id"], result}

        {{:exit, :timeout}, anchor} ->
          result = failed_result(anchor, checked_at, correlation, "transport", "Anchor timed out")
          {anchor["id"], result}

        {{:exit, _reason}, anchor} ->
          result =
            failed_result(anchor, checked_at, correlation, "assertion", "Anchor process failed")

          {anchor["id"], result}
      end)

    Enum.map(plans, fn plan ->
      Map.get(executed, plan["id"], finalize_plan(plan, checked_at, correlation))
    end)
  end

  @doc "Builds a sanitized report with an embedded schema-compatible evidence artifact."
  @spec report(map(), [map()], keyword()) :: map()
  def report(config, results, opts \\ []) when is_map(config) and is_list(results) do
    checked_at = Keyword.get(opts, :checked_at, checked_at_from_results(results))
    correlation = Keyword.get(opts, :correlation, %{})
    mode = if Keyword.get(opts, :dry_run, false), do: "dry_run", else: "live_probe"

    %{
      "schema_version" => @report_schema_version,
      "kind" => "req_llm_provider_drift",
      "mode" => mode,
      "generated_at" => DateTime.to_iso8601(checked_at),
      "correlation" => correlation,
      "limits" => config["limits"],
      "summary" => summarize(results),
      "results" => results,
      "evidence" => evidence(results, checked_at)
    }
  end

  @doc "Returns a compatibility evidence document containing completed probes only."
  @spec evidence([map()], DateTime.t()) :: map()
  def evidence(results, %DateTime{} = checked_at) do
    results
    |> Enum.filter(&(&1["status"] in ["pass", "fail"]))
    |> Enum.reduce(Evidence.migrate(%{}), fn result, acc ->
      evidence_result = %{
        model_spec: result["model_spec"],
        provider: String.to_existing_atom(result["provider"]),
        model_id: result["model"],
        status: String.to_existing_atom(result["status"]),
        scenarios: [
          %{
            "scenario" => result["scenario"],
            "status" => result["status"],
            "fixtures" => result["fixtures"],
            "failure_layer" => result["failure_layer"],
            "error" => sanitized_evidence_error(result)
          }
        ]
      }

      Evidence.record(acc, [evidence_result], checked_at, "live_probe",
        surface_resolver: fn _model_spec, _operation, _fixtures -> result["surface"] end
      )
    end)
  end

  @doc "Renders a concise GitHub step summary without provider payloads."
  @spec markdown(map()) :: binary()
  def markdown(report) when is_map(report) do
    summary = report["summary"]
    limits = report["limits"]

    rows =
      report["results"]
      |> Enum.map_join("\n", fn result ->
        "| #{cell(result["provider"])} | #{cell(result["model"])} | " <>
          "#{cell(result["surface"] || result["expected_surface"])} | " <>
          "#{cell(result["scenario"])} | #{cell(result["status"])} | " <>
          "#{cell(result["failure_layer"] || "—")} | #{cell(result["remediation"])} |"
      end)

    """
    ## ReqLLM provider drift verification

    - Mode: `#{report["mode"]}`
    - Correlation: `#{correlation_label(report["correlation"])}`
    - Results: #{summary["pass"]} passed, #{summary["fail"]} failed, #{summary["skipped"]} skipped, #{summary["planned"]} planned
    - Selected budget: #{summary["total"]}/#{limits["max_anchors"]} anchors, estimated maximum $#{format_cost(summary["estimated_max_cost_usd"])}
    - Guardrails: concurrency #{limits["max_concurrency"]}, #{limits["timeout_seconds"]}s per anchor, #{limits["max_output_tokens_per_anchor"]} output tokens per anchor, matrix maximum $#{format_cost(limits["estimated_max_cost_usd"])}

    | Provider | Model | Surface | Scenario | Status | Failure layer | Remediation |
    | --- | --- | --- | --- | --- | --- | --- |
    #{rows}
    """
  end

  @doc "Writes deterministic JSON and Markdown report files."
  @spec write_report!(Path.t(), Path.t(), map()) :: :ok
  def write_report!(json_path, markdown_path, report) do
    json_path |> Path.dirname() |> File.mkdir_p!()
    markdown_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(json_path, Evidence.canonical_json(report))
    File.write!(markdown_path, markdown(report))
  end

  @doc "Returns true when any executed anchor failed."
  @spec failures?([map()]) :: boolean()
  def failures?(results), do: Enum.any?(results, &(&1["status"] == "fail"))

  defp validate_limits!(limits) do
    require_positive_integer!(limits["max_anchors"], "limits.max_anchors")
    require_positive_integer!(limits["max_concurrency"], "limits.max_concurrency")
    require_positive_integer!(limits["timeout_seconds"], "limits.timeout_seconds")

    require_positive_integer!(
      limits["max_output_tokens_per_anchor"],
      "limits.max_output_tokens_per_anchor"
    )

    require_non_negative_number!(
      limits["estimated_max_cost_usd"],
      "limits.estimated_max_cost_usd"
    )

    if limits["max_concurrency"] > limits["max_anchors"] do
      raise ArgumentError, "limits.max_concurrency cannot exceed limits.max_anchors"
    end
  end

  defp validate_anchor_count!(anchors, limits) do
    if length(anchors) > limits["max_anchors"] do
      raise ArgumentError,
            "anchor count #{length(anchors)} exceeds limits.max_anchors #{limits["max_anchors"]}"
    end
  end

  defp validate_unique_anchor_ids!(anchors) do
    ids = Enum.map(anchors, &require_binary!(&1["id"], "anchor.id"))

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "anchor ids must be unique"
    end
  end

  defp validate_anchor!(anchor, limits, evidence) when is_map(anchor) do
    id = require_binary!(anchor["id"], "anchor.id")
    provider = require_binary!(anchor["provider"], "#{id}.provider")
    model = require_binary!(anchor["model"], "#{id}.model")
    operation = require_member!(anchor["operation"], @operations, "#{id}.operation")
    surface = require_binary!(anchor["surface"], "#{id}.surface")
    scenario_id = require_binary!(anchor["scenario"], "#{id}.scenario")
    credentials = require_non_empty_list!(anchor["credential_env"], "#{id}.credential_env")
    max_tokens = require_positive_integer!(anchor["max_output_tokens"], "#{id}.max_output_tokens")

    require_non_negative_number!(
      anchor["estimated_max_cost_usd"],
      "#{id}.estimated_max_cost_usd"
    )

    if max_tokens > limits["max_output_tokens_per_anchor"] do
      raise ArgumentError,
            "#{id}.max_output_tokens exceeds limits.max_output_tokens_per_anchor"
    end

    Enum.each(credentials, &validate_credential_name!(&1, id))

    scenario = ScenarioCatalog.fetch_scenario!(scenario_id)

    if Atom.to_string(scenario.operation) != operation do
      raise ArgumentError, "#{id}.scenario operation does not match #{operation}"
    end

    applicable_providers =
      if scenario.providers == :all, do: :all, else: Enum.map(scenario.providers, &to_string/1)

    if applicable_providers != :all and provider not in applicable_providers do
      raise ArgumentError, "#{id}.scenario does not apply to provider #{provider}"
    end

    model_spec = "#{provider}:#{model}"

    unless is_map(get_in(evidence, ["models", model_spec, "surfaces", surface])) do
      raise ArgumentError, "#{id}.surface is not present in checked-in compatibility evidence"
    end

    unless is_map(
             get_in(evidence, [
               "models",
               model_spec,
               "surfaces",
               surface,
               "scenarios",
               scenario_id
             ])
           ) do
      raise ArgumentError, "#{id}.scenario is not recorded on expected surface #{surface}"
    end
  end

  defp validate_anchor!(_anchor, _limits, _evidence) do
    raise ArgumentError, "each anchor must be an object"
  end

  defp validate_cost_budget!(anchors, limits) do
    estimated = Enum.reduce(anchors, 0.0, &(&1["estimated_max_cost_usd"] + &2))

    if estimated > limits["estimated_max_cost_usd"] do
      raise ArgumentError,
            "anchor estimated cost #{format_cost(estimated)} exceeds configured maximum " <>
              format_cost(limits["estimated_max_cost_usd"])
    end
  end

  defp plan_anchor(anchor, _env, true) do
    anchor
    |> anchor_identity()
    |> Map.merge(%{
      "status" => "planned",
      "missing_credentials" => [],
      "failure_layer" => nil,
      "remediation" => "Dry run only; no provider request was made"
    })
  end

  defp plan_anchor(anchor, env, false) do
    missing = Enum.reject(anchor["credential_env"], &credential_present?(env[&1]))

    if missing == [] do
      anchor
      |> anchor_identity()
      |> Map.merge(%{
        "status" => "ready",
        "missing_credentials" => [],
        "failure_layer" => nil,
        "remediation" => "Run the bounded live probe"
      })
    else
      anchor
      |> anchor_identity()
      |> Map.merge(%{
        "status" => "skipped",
        "missing_credentials" => missing,
        "failure_layer" => nil,
        "remediation" => "Configure repository secret(s): #{Enum.join(missing, ", ")}"
      })
    end
  end

  defp anchor_identity(anchor) do
    %{
      "id" => anchor["id"],
      "provider" => anchor["provider"],
      "model" => anchor["model"],
      "model_spec" => "#{anchor["provider"]}:#{anchor["model"]}",
      "operation" => anchor["operation"],
      "expected_surface" => anchor["surface"],
      "surface" => anchor["surface"],
      "scenario" => anchor["scenario"],
      "fixtures" => ScenarioCatalog.fixtures(anchor["scenario"]),
      "estimated_max_cost_usd" => anchor["estimated_max_cost_usd"],
      "max_output_tokens" => anchor["max_output_tokens"]
    }
  end

  defp normalize_execution_result(anchor, result, checked_at, correlation, duration_ms)
       when is_map(result) do
    status = result["status"] || result[:status]
    surface = result["surface"] || result[:surface] || anchor["expected_surface"]
    fixtures = result["fixtures"] || result[:fixtures] || anchor["fixtures"]
    failure_layer = result["failure_layer"] || result[:failure_layer]

    {status, failure_layer, remediation} =
      normalize_execution_status(
        status,
        failure_layer,
        surface,
        anchor["expected_surface"],
        result["remediation"] || result[:remediation]
      )

    anchor
    |> Map.merge(%{
      "status" => status,
      "surface" => surface,
      "fixtures" => fixtures,
      "failure_layer" => failure_layer,
      "remediation" => remediation,
      "checked_at" => DateTime.to_iso8601(checked_at),
      "duration_ms" => duration_ms,
      "correlation_id" => correlation_id(correlation, anchor["id"]),
      "missing_credentials" => []
    })
  end

  defp normalize_execution_result(anchor, _result, checked_at, correlation, _duration_ms) do
    failed_result(anchor, checked_at, correlation, "assertion", "Anchor returned invalid data")
  end

  defp normalize_execution_status(
         "pass",
         _failure_layer,
         surface,
         expected_surface,
         _remediation
       )
       when surface != expected_surface do
    {"fail", "provider_drift",
     "Observed surface changed from #{expected_surface} to #{surface}; inspect routing before updating evidence"}
  end

  defp normalize_execution_status("pass", _failure_layer, _surface, _expected, _remediation) do
    {"pass", nil, "No action required"}
  end

  defp normalize_execution_status("fail", failure_layer, _surface, _expected, remediation) do
    layer = if failure_layer in Evidence.failure_layers(), do: failure_layer, else: "assertion"
    {"fail", layer, remediation || remediation_for(layer)}
  end

  defp normalize_execution_status(_status, _failure_layer, _surface, _expected, _remediation) do
    {"fail", "assertion", "Anchor returned an invalid status"}
  end

  defp failed_result(anchor, checked_at, correlation, layer, remediation) do
    anchor
    |> Map.merge(%{
      "status" => "fail",
      "failure_layer" => layer,
      "remediation" => remediation,
      "checked_at" => DateTime.to_iso8601(checked_at),
      "duration_ms" => nil,
      "correlation_id" => correlation_id(correlation, anchor["id"]),
      "missing_credentials" => []
    })
  end

  defp finalize_plan(plan, checked_at, correlation) do
    plan
    |> Map.put("checked_at", DateTime.to_iso8601(checked_at))
    |> Map.put("duration_ms", 0)
    |> Map.put("correlation_id", correlation_id(correlation, plan["id"]))
  end

  defp summarize(results) do
    counts = Enum.frequencies_by(results, & &1["status"])

    %{
      "total" => length(results),
      "pass" => Map.get(counts, "pass", 0),
      "fail" => Map.get(counts, "fail", 0),
      "skipped" => Map.get(counts, "skipped", 0),
      "planned" => Map.get(counts, "planned", 0),
      "estimated_max_cost_usd" => Enum.reduce(results, 0.0, &(&1["estimated_max_cost_usd"] + &2))
    }
  end

  defp sanitized_evidence_error(%{"status" => "fail", "failure_layer" => layer}) do
    "Live provider probe failed at #{layer || "assertion"}; see the sanitized drift report"
  end

  defp sanitized_evidence_error(_result), do: nil

  defp remediation_for("resolution"), do: "Verify the anchor model ID and current catalog entry"
  defp remediation_for("planning"), do: "Verify scenario routing and anchor configuration"
  defp remediation_for("encoding"), do: "Inspect provider request translation for the scenario"

  defp remediation_for("transport"),
    do: "Retry once, then inspect network and provider availability"

  defp remediation_for("decoding"),
    do: "Inspect the provider response decoder against current wire data"

  defp remediation_for("materialization"),
    do: "Inspect response assembly and recorded surface extraction"

  defp remediation_for("provider_drift"),
    do: "Inspect provider status, API changes, and the expected execution surface"

  defp remediation_for(_layer), do: "Inspect the focused compatibility assertion"

  defp checked_at_from_results([%{"checked_at" => checked_at} | _]) when is_binary(checked_at) do
    case DateTime.from_iso8601(checked_at) do
      {:ok, parsed, _offset} -> parsed
      _error -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp checked_at_from_results(_results), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp provider_filter([]), do: MapSet.new()
  defp provider_filter(["all"]), do: MapSet.new()
  defp provider_filter(providers), do: MapSet.new(providers)

  defp selected_provider?(anchor, providers) do
    MapSet.size(providers) == 0 or MapSet.member?(providers, anchor["provider"])
  end

  defp credential_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp credential_present?(_value), do: false

  defp validate_credential_name!(name, id) when is_binary(name) do
    unless Regex.match?(@credential_name, name) do
      raise ArgumentError, "#{id}.credential_env contains invalid name #{inspect(name)}"
    end
  end

  defp validate_credential_name!(_name, id) do
    raise ArgumentError, "#{id}.credential_env entries must be strings"
  end

  defp correlation_id(correlation, anchor_id) do
    run_id = correlation["run_id"] || correlation[:run_id] || "local"
    attempt = correlation["run_attempt"] || correlation[:run_attempt] || "1"
    "#{run_id}-#{attempt}-#{anchor_id}"
  end

  defp correlation_label(correlation) do
    run_id = correlation["run_id"] || correlation[:run_id] || "local"
    attempt = correlation["run_attempt"] || correlation[:run_attempt] || "1"
    "#{run_id}/#{attempt}"
  end

  defp cell(nil), do: "—"

  defp cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace(~r/[\r\n]+/, " ")
  end

  defp format_cost(value) when is_integer(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp format_cost(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp require_equal!(actual, expected, field) do
    unless actual == expected do
      raise ArgumentError, "#{field} must be #{inspect(expected)}, got: #{inspect(actual)}"
    end
  end

  defp require_map!(value, _field) when is_map(value), do: value

  defp require_map!(value, field),
    do: raise(ArgumentError, "#{field} must be an object, got: #{inspect(value)}")

  defp require_non_empty_list!(value, _field) when is_list(value) and value != [], do: value

  defp require_non_empty_list!(value, field) do
    raise ArgumentError, "#{field} must be a non-empty list, got: #{inspect(value)}"
  end

  defp require_binary!(value, _field) when is_binary(value) and value != "", do: value

  defp require_binary!(value, field),
    do: raise(ArgumentError, "#{field} must be a non-empty string, got: #{inspect(value)}")

  defp require_member!(value, members, field) do
    if value in members do
      value
    else
      raise ArgumentError,
            "#{field} must be one of #{Enum.join(members, ", ")}, got: #{inspect(value)}"
    end
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp require_positive_integer!(value, field) do
    raise ArgumentError, "#{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp require_non_negative_number!(value, _field) when is_number(value) and value >= 0, do: value

  defp require_non_negative_number!(value, field) do
    raise ArgumentError, "#{field} must be a non-negative number, got: #{inspect(value)}"
  end
end
