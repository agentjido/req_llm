defmodule ReqLLM.Compatibility.SupportReference do
  @moduledoc """
  Deterministic Markdown generation from compatibility catalog and evidence.
  """

  alias ReqLLM.Compatibility.{Evidence, ScenarioCatalog}

  @doc "Renders the checked-in model support evidence reference."
  @spec render(map(), keyword()) :: binary()
  def render(evidence, opts \\ []) do
    as_of = Keyword.get(opts, :as_of, evidence["generated_at"])
    rows = rows(evidence, as_of: as_of)
    counts = Enum.frequencies_by(rows, & &1.status.tier)

    [
      "# Model Support Evidence\n\n",
      intro(evidence, as_of),
      tier_definitions(),
      summary(counts, length(rows)),
      provider_tables(rows)
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Returns deterministic model/surface rows used by the reference."
  @spec rows(map(), keyword()) :: [map()]
  def rows(evidence, opts \\ []) do
    as_of = Keyword.get(opts, :as_of, evidence["generated_at"])

    evidence
    |> Map.get("models", %{})
    |> Enum.flat_map(fn {model_spec, model} ->
      statuses = Evidence.model_surface_statuses(evidence, model_spec, as_of: as_of)

      Enum.map(statuses, fn status ->
        surface = get_in(model, ["surfaces", status.surface]) || %{}

        %{
          model_spec: model_spec,
          provider: model["provider"],
          model: model["model"],
          surface: status.surface,
          operation: status.operation,
          modalities: modalities(surface),
          observed_scenarios: map_size(surface["scenarios"] || %{}),
          status: status
        }
      end)
    end)
    |> Enum.sort_by(&{&1.provider, &1.model, &1.surface})
  end

  defp intro(evidence, as_of) do
    """
    This file is generated from `priv/model_compat_scenarios.json` and the compiled
    compatibility scenario catalog. It is a tooling snapshot, not a runtime model
    allowlist, and it does not change whether ReqLLM can resolve or call a model.

    - Evidence schema: `#{evidence["schema_version"]}`
    - Snapshot evaluated at: `#{as_of || "unknown"}`
    - Freshness window: `#{Evidence.freshness_days()} days`

    """
  end

  defp tier_definitions do
    """
    ## Conservative tier rules

    - **First-class**: every fixture-replay baseline scenario for this exact
      execution surface has current passing evidence.
    - **Best-effort**: at least one baseline scenario has current passing evidence,
      but the baseline is incomplete.
    - **Experimental**: evidence is missing, stale, or no fixture-replay baseline is
      defined. Catalog presence alone never promotes a surface.
    - **Unsupported**: a required baseline scenario has explicit failing evidence;
      the reason includes its classified failure layer.

    A recorded operation that current model metadata does not declare is unsupported
    for that operation. Evidence for a model absent from the current catalog remains
    experimental rather than becoming a support claim.

    These labels describe evidence for a model surface. They do not describe every
    provider-native feature and are not consulted by request routing.

    """
  end

  defp summary(counts, total) do
    """
    ## Snapshot summary

    | Tier | Surfaces |
    | --- | ---: |
    | First-class | #{Map.get(counts, :first_class, 0)} |
    | Best-effort | #{Map.get(counts, :best_effort, 0)} |
    | Experimental | #{Map.get(counts, :experimental, 0)} |
    | Unsupported | #{Map.get(counts, :unsupported, 0)} |
    | **Total recorded surfaces** | **#{total}** |

    """
  end

  defp provider_tables(rows) do
    rows
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {provider, _rows} -> provider end)
    |> Enum.map(fn {provider, provider_rows} ->
      [
        "## ",
        provider,
        "\n\n",
        "| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |\n",
        "| --- | --- | --- | --- | --- | ---: | --- | --- |\n",
        Enum.map(provider_rows, &row/1),
        "\n"
      ]
    end)
  end

  defp row(row) do
    status = row.status
    passed = length(status.required_scenarios) - length(status.missing_scenarios)
    baseline = "#{passed}/#{length(status.required_scenarios)}"

    [
      "| `",
      markdown(row.model),
      "` | `",
      Atom.to_string(row.operation),
      "` | `",
      markdown(row.surface),
      "` | ",
      markdown(modality_text(row.modalities)),
      " | ",
      tier_text(status.tier),
      " | ",
      baseline,
      " | ",
      status.checked_at || "—",
      " | ",
      markdown(reason_text(status)),
      " |\n"
    ]
  end

  defp modalities(surface) do
    scenarios = Map.keys(surface["scenarios"] || %{})

    Enum.reduce(scenarios, %{input: MapSet.new(), output: MapSet.new()}, fn scenario_id, acc ->
      case ScenarioCatalog.fetch_scenario(scenario_id) do
        {:ok, scenario} ->
          %{
            input: MapSet.union(acc.input, MapSet.new(scenario.input_modalities)),
            output: MapSet.union(acc.output, MapSet.new(scenario.output_modalities))
          }

        :error ->
          acc
      end
    end)
  end

  defp modality_text(%{input: input, output: output}) do
    "#{join_modalities(input)} → #{join_modalities(output)}"
  end

  defp join_modalities(modalities) do
    modalities
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.join(", ")
    |> case do
      "" -> "unknown"
      joined -> joined
    end
  end

  defp tier_text(:first_class), do: "First-class"
  defp tier_text(:best_effort), do: "Best-effort"
  defp tier_text(:experimental), do: "Experimental"
  defp tier_text(:unsupported), do: "Unsupported"

  defp reason_text(%{reason: :complete_current_baseline}), do: "complete current baseline"

  defp reason_text(%{reason: :partial_current_baseline, missing_scenarios: missing}) do
    "missing current evidence: #{Enum.join(missing, ", ")}"
  end

  defp reason_text(%{
         reason: :baseline_failure,
         scenario: scenario,
         failure_layer: failure_layer
       }) do
    "#{scenario} failed at #{failure_layer}"
  end

  defp reason_text(%{reason: :no_fixture_backed_baseline}), do: "no fixture-replay baseline"
  defp reason_text(%{reason: :missing_evidence}), do: "missing evidence"
  defp reason_text(%{reason: :missing_or_stale_evidence}), do: "missing or stale evidence"
  defp reason_text(%{reason: :operation_not_declared}), do: "operation not declared"
  defp reason_text(%{reason: :surface_declaration_unknown}), do: "surface declaration unknown"
  defp reason_text(status), do: status.reason |> to_string() |> String.replace("_", " ")

  defp markdown(value), do: value |> to_string() |> String.replace("|", "\\|")
end
