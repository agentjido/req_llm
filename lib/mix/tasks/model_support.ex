defmodule Mix.Tasks.ReqLlm.ModelSupport do
  @shortdoc "Inspect or generate evidence-backed model support tiers"
  @moduledoc """
  Inspect evidence-backed support tiers without changing model resolution.

      mix req_llm.model_support
      mix req_llm.model_support --model openai:gpt-4o-mini
      mix req_llm.model_support --generate
      mix req_llm.model_support --check
  """

  use Mix.Task

  alias ReqLLM.Compatibility.{Evidence, SupportReference}

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [generate: :boolean, check: :boolean, model: :string]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    cond do
      opts[:generate] -> generate(load_source_evidence())
      opts[:check] -> check(load_source_evidence())
      opts[:model] -> print_model(Evidence.load!(), opts[:model])
      true -> print_summary(Evidence.load!())
    end
  end

  @doc false
  def evidence_path, do: Path.expand("priv/model_compat_scenarios.json")

  @doc false
  def reference_path, do: Path.expand("guides/model-support.md")

  defp load_source_evidence do
    Evidence.load!(evidence_path(), surface_resolver: surface_resolver())
  end

  defp generate(evidence) do
    evidence = refresh_evidence(evidence)

    Evidence.write!(evidence_path(), evidence)
    File.write!(reference_path(), SupportReference.render(evidence))
    Mix.shell().info("Generated #{evidence_path()} and #{reference_path()}")
  end

  defp check(evidence) do
    evidence = refresh_evidence(evidence)
    expected_evidence = Evidence.canonical_json(evidence)
    expected_reference = SupportReference.render(evidence)

    with {:ok, ^expected_evidence} <- File.read(evidence_path()),
         {:ok, ^expected_reference} <- File.read(reference_path()) do
      Mix.shell().info("Compatibility evidence and support reference are current")
    else
      _mismatch -> Mix.raise("Compatibility evidence or support reference is not generated")
    end
  end

  @doc false
  def refresh_evidence(evidence) do
    evidence
    |> Evidence.resolve_surfaces(surface_resolver())
    |> Evidence.annotate_declarations(packaged_catalog_resolver())
  end

  defp print_summary(evidence) do
    rows = SupportReference.rows(evidence, as_of: DateTime.utc_now())
    counts = Enum.frequencies_by(rows, & &1.status.tier)

    Mix.shell().info(
      "Evidence schema #{evidence["schema_version"]} (#{evidence["generated_at"]})"
    )

    Mix.shell().info("Recorded models: #{map_size(evidence["models"] || %{})}")
    Mix.shell().info("First-class surfaces: #{Map.get(counts, :first_class, 0)}")
    Mix.shell().info("Best-effort surfaces: #{Map.get(counts, :best_effort, 0)}")
    Mix.shell().info("Experimental surfaces: #{Map.get(counts, :experimental, 0)}")
    Mix.shell().info("Unsupported surfaces: #{Map.get(counts, :unsupported, 0)}")
  end

  defp print_model(evidence, model_spec) do
    statuses = Evidence.model_surface_statuses(evidence, model_spec, as_of: DateTime.utc_now())

    if statuses == [] do
      Mix.shell().info("#{model_spec}: experimental (missing evidence)")
    else
      Enum.each(statuses, fn status ->
        Mix.shell().info("#{model_spec} #{status.surface}: #{status.tier} (#{status.reason})")
      end)
    end
  end

  defp surface_resolver do
    fixture_root = Path.expand("test/support/fixtures")

    fn model_spec, operation, fixtures ->
      Evidence.fixture_surface(fixture_root, model_spec, operation, fixtures)
    end
  end

  defp packaged_catalog_resolver do
    case LLMDB.Loader.load(custom: %{}) do
      {:ok, snapshot} ->
        direct_models =
          Map.new(snapshot.models_by_key, fn {{provider, model_id}, model} ->
            {"#{provider}:#{model_id}", model}
          end)

        alias_models =
          Map.new(snapshot.aliases_by_key, fn {{provider, alias_id}, model_id} ->
            {"#{provider}:#{alias_id}", Map.fetch!(snapshot.models_by_key, {provider, model_id})}
          end)

        models_by_spec = Map.merge(direct_models, alias_models)

        fn model_spec ->
          case Map.fetch(models_by_spec, model_spec) do
            {:ok, model} -> {:ok, model}
            :error -> {:error, :unknown_model}
          end
        end

      {:error, reason} ->
        raise ArgumentError, "cannot load packaged LLMDB catalog: #{inspect(reason)}"
    end
  end
end
