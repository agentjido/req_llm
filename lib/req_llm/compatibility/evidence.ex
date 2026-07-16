defmodule ReqLLM.Compatibility.Evidence do
  @moduledoc """
  Versioned compatibility evidence for models, execution surfaces, and scenarios.

  Evidence is tooling metadata. It does not participate in model resolution or
  request routing.
  """

  alias ReqLLM.Compatibility.ScenarioCatalog

  @schema_version 1
  @freshness_days 90
  @failure_layers ~w(resolution planning encoding transport decoding materialization assertion provider_drift)

  @type tier :: :first_class | :best_effort | :experimental | :unsupported

  @doc "Returns the current evidence schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the default evidence freshness window in days."
  @spec freshness_days() :: pos_integer()
  def freshness_days, do: @freshness_days

  @doc "Returns the supported failure-layer names."
  @spec failure_layers() :: [binary()]
  def failure_layers, do: @failure_layers

  @doc "Loads and migrates compatibility evidence from disk."
  @spec load(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(path \\ default_path(), opts \\ []) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, migrate(decoded, opts)}
    end
  end

  @doc "Loads compatibility evidence or raises."
  @spec load!(Path.t(), keyword()) :: map()
  def load!(path \\ default_path(), opts \\ []) do
    case load(path, opts) do
      {:ok, evidence} ->
        evidence

      {:error, reason} ->
        raise ArgumentError, "cannot load compatibility evidence: #{inspect(reason)}"
    end
  end

  @doc "Migrates legacy scenario state into the current evidence schema."
  @spec migrate(map(), keyword()) :: map()
  def migrate(evidence, opts \\ [])

  def migrate(%{"schema_version" => @schema_version, "models" => models} = evidence, _opts)
      when is_map(models) do
    evidence
  end

  def migrate(%{"schema_version" => version}, _opts) do
    raise ArgumentError,
          "unsupported compatibility evidence schema version: #{inspect(version)}"
  end

  def migrate(legacy, opts) when is_map(legacy) do
    surface_resolver = Keyword.get(opts, :surface_resolver, &default_surface_resolver/3)

    models =
      legacy
      |> Enum.sort_by(fn {model_spec, _state} -> model_spec end)
      |> Enum.reduce(%{}, fn {model_spec, model_state}, acc ->
        Map.put(acc, model_spec, migrate_legacy_model(model_spec, model_state, surface_resolver))
      end)

    %{
      "schema_version" => @schema_version,
      "generated_at" => latest_checked_at(models),
      "models" => models
    }
  end

  @doc "Records scenario results without discarding prior observations."
  @spec record(map(), [map()], DateTime.t(), binary(), keyword()) :: map()
  def record(evidence, results, %DateTime{} = checked_at, mode, opts \\ [])
      when is_list(results) and is_binary(mode) do
    surface_resolver = Keyword.get(opts, :surface_resolver, &default_surface_resolver/3)
    checked_at = checked_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    models =
      Enum.reduce(results, evidence["models"] || %{}, fn result, acc ->
        record_result(acc, result, checked_at, mode, surface_resolver)
      end)

    evidence
    |> Map.put("schema_version", @schema_version)
    |> Map.put("generated_at", checked_at)
    |> Map.put("models", models)
  end

  @doc "Reindexes recorded scenarios from their fixture-backed execution surfaces."
  @spec resolve_surfaces(map(), (binary(), atom(), [binary()] -> binary() | nil)) :: map()
  def resolve_surfaces(evidence, surface_resolver) when is_function(surface_resolver, 3) do
    models =
      evidence
      |> Map.get("models", %{})
      |> Map.new(fn {model_spec, model} ->
        {provider, _model_id} = split_model_spec(model_spec)

        surfaces =
          model
          |> Map.get("surfaces", %{})
          |> Enum.reduce(%{}, fn {existing_surface_id, surface}, acc ->
            operation = operation_atom!(surface["operation"])

            surface
            |> Map.get("scenarios", %{})
            |> Enum.reduce(acc, fn {scenario_id, scenario}, scenario_acc ->
              fixtures = scenario_fixtures(scenario)

              surface_id =
                surface_resolver.(model_spec, operation, fixtures) ||
                  normalize_unrecorded_surface(existing_surface_id, provider, operation)

              merge_surface_scenario(
                scenario_acc,
                surface_id,
                provider,
                operation,
                scenario_id,
                scenario
              )
            end)
          end)

        {model_spec, Map.put(model, "surfaces", surfaces)}
      end)

    Map.put(evidence, "models", models)
  end

  @doc "Annotates recorded surfaces with current catalog operation declarations."
  @spec annotate_declarations(map(), (binary() -> {:ok, LLMDB.Model.t()} | {:error, term()})) ::
          map()
  def annotate_declarations(evidence, resolver \\ &LLMDB.model/1) when is_function(resolver, 1) do
    models =
      evidence
      |> Map.get("models", %{})
      |> Map.new(fn {model_spec, model} ->
        {catalog_status, declared_operations} = declared_operations(resolver.(model_spec))

        surfaces =
          model
          |> Map.get("surfaces", %{})
          |> Map.new(fn {surface_id, surface} ->
            declaration =
              surface_declaration(surface["operation"], catalog_status, declared_operations)

            {surface_id, Map.put(surface, "declaration", declaration)}
          end)

        annotated =
          model
          |> Map.put("catalog_status", catalog_status)
          |> Map.put("declared_operations", declared_operations)
          |> Map.put("surfaces", surfaces)

        {model_spec, annotated}
      end)

    Map.put(evidence, "models", models)
  end

  @doc "Writes evidence as deterministic, recursively key-sorted JSON."
  @spec write!(Path.t(), map()) :: :ok
  def write!(path, evidence) do
    File.write!(path, canonical_json(evidence))
  end

  @doc "Encodes evidence as deterministic, recursively key-sorted JSON."
  @spec canonical_json(map()) :: binary()
  def canonical_json(evidence) do
    evidence
    |> ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc "Returns the evidence-derived status for one declared operation."
  @spec support_status(map(), binary(), atom(), keyword()) :: map()
  def support_status(evidence, model_spec, operation, opts \\ [])
      when is_binary(model_spec) and is_atom(operation) do
    if Keyword.get(opts, :declared?, true) do
      statuses =
        evidence
        |> surface_entries(model_spec)
        |> Enum.filter(fn {_surface_id, surface} ->
          surface["operation"] == Atom.to_string(operation)
        end)
        |> Enum.map(fn {surface_id, surface} ->
          surface_status(surface_id, surface, operation, opts)
        end)

      aggregate_operation_status(operation, statuses)
    else
      status(:unsupported, :operation_not_declared, operation, [], [], nil)
    end
  end

  @doc "Returns evidence-derived statuses for every recorded surface of a model."
  @spec model_surface_statuses(map(), binary(), keyword()) :: [map()]
  def model_surface_statuses(evidence, model_spec, opts \\ []) when is_binary(model_spec) do
    evidence
    |> surface_entries(model_spec)
    |> Enum.map(fn {surface_id, surface} ->
      operation = operation_atom!(surface["operation"])
      surface_status(surface_id, surface, operation, opts)
    end)
    |> Enum.sort_by(& &1.surface)
  end

  @doc "Classifies a failed execution into a stable compatibility layer."
  @spec classify_failure(binary() | nil) :: binary() | nil
  def classify_failure(nil), do: nil

  def classify_failure(error) when is_binary(error) do
    normalized = String.downcase(error)

    cond do
      contains_any?(normalized, [
        "unknown model",
        "model not found",
        "could not resolve",
        "no models match"
      ]) ->
        "resolution"

      contains_any?(normalized, [
        "no replayable",
        "execution plan",
        "planning",
        "no matching compatibility tests"
      ]) ->
        "planning"

      contains_any?(normalized, ["encode", "encoding", "request body", "invalid schema"]) ->
        "encoding"

      contains_any?(normalized, ["decode", "decoding", "invalid json", "parse response"]) ->
        "decoding"

      contains_any?(normalized, [
        "materializ",
        "response builder",
        "responsebuilder",
        "assemble response"
      ]) ->
        "materialization"

      contains_any?(normalized, [
        "timed out",
        "timeout",
        "econn",
        "connection",
        "finch",
        "mint.transport"
      ]) ->
        "transport"

      contains_any?(normalized, [
        "provider response",
        "status 4",
        "status 5",
        "http 4",
        "http 5",
        "rate limit"
      ]) ->
        "provider_drift"

      true ->
        "assertion"
    end
  end

  @doc "Resolves a stable execution-surface ID from recorded fixture request URLs."
  @spec fixture_surface(Path.t(), binary(), atom(), [binary()]) :: binary() | nil
  def fixture_surface(fixture_root, model_spec, operation, fixtures)
      when is_binary(model_spec) and is_atom(operation) and is_list(fixtures) do
    {provider, model_id} = split_model_spec(model_spec)

    families =
      fixtures
      |> Enum.flat_map(&fixture_urls(fixture_root, provider, model_id, &1))
      |> Enum.map(&surface_family(&1, operation))
      |> Enum.uniq()
      |> Enum.sort()

    case families do
      [] -> nil
      families -> "#{provider}.#{Enum.join(families, "+")}"
    end
  end

  @doc "Returns the default checked-in evidence path."
  @spec default_path() :: Path.t()
  def default_path do
    :req_llm
    |> :code.priv_dir()
    |> Path.join("model_compat_scenarios.json")
  end

  defp migrate_legacy_model(model_spec, model_state, surface_resolver) do
    {provider, model_id} = split_model_spec(model_spec)
    scenarios = if is_map(model_state), do: model_state["scenarios"] || %{}, else: %{}

    surfaces =
      scenarios
      |> Enum.sort_by(fn {scenario_id, _state} -> scenario_id end)
      |> Enum.reduce(%{}, fn {scenario_id, scenario_state}, acc ->
        metadata = scenario_metadata(scenario_id)
        operation = metadata.operation
        fixtures = scenario_state["fixtures"] || []

        surface_id =
          surface_resolver.(model_spec, operation, fixtures) ||
            fallback_surface(provider, operation)

        observation = legacy_observation(scenario_state)

        put_surface_observation(
          acc,
          surface_id,
          provider,
          operation,
          scenario_id,
          metadata.proof,
          observation
        )
      end)

    model = %{
      "provider" => provider,
      "model" => model_id,
      "surfaces" => surfaces
    }

    legacy_metadata =
      if is_map(model_state), do: Map.drop(model_state, ["scenarios"]), else: %{}

    maybe_put(model, "legacy_metadata", legacy_metadata)
  end

  defp legacy_observation(scenario_state) do
    error = scenario_state["error"]
    status = scenario_state["status"] || "fail"

    observation = %{
      "status" => status,
      "checked_at" => scenario_state["last_checked"],
      "mode" => scenario_state["mode"] || "unknown",
      "fixtures" => scenario_state["fixtures"] || [],
      "failure_layer" => if(status == "pass", do: nil, else: classify_failure(error)),
      "error" => error
    }

    legacy_metadata =
      Map.drop(scenario_state, ["status", "last_checked", "mode", "fixtures", "error"])

    maybe_put(observation, "legacy_metadata", legacy_metadata)
  end

  defp record_result(models, result, checked_at, mode, surface_resolver) do
    model_spec = result.model_spec
    {provider, model_id} = split_model_spec(model_spec)

    model =
      Map.get(models, model_spec, %{
        "provider" => provider,
        "model" => model_id,
        "surfaces" => %{}
      })

    scenarios = Map.get(result, :scenarios) || result_scenarios(result)

    surfaces =
      Enum.reduce(scenarios, model["surfaces"] || %{}, fn scenario, acc ->
        record_scenario(
          acc,
          model_spec,
          provider,
          scenario,
          checked_at,
          mode,
          surface_resolver
        )
      end)

    Map.put(models, model_spec, Map.put(model, "surfaces", surfaces))
  end

  defp result_scenarios(%{scenario: nil}), do: []

  defp result_scenarios(result) do
    [
      %{
        "scenario" => result.scenario,
        "status" => Atom.to_string(result.status),
        "fixtures" => result.fixtures,
        "failure_layer" => result.failure_layer,
        "error" => result.error
      }
    ]
  end

  defp record_scenario(
         surfaces,
         model_spec,
         provider,
         scenario,
         checked_at,
         mode,
         surface_resolver
       ) do
    scenario_id = scenario["scenario"]
    metadata = scenario_metadata(scenario_id)
    fixtures = scenario["fixtures"] || []
    resolved_surface = surface_resolver.(model_spec, metadata.operation, fixtures)
    existing_surface = find_scenario_surface(surfaces, scenario_id)

    validate_surface_change!(existing_surface, resolved_surface, scenario_id, model_spec, mode)

    surface_id =
      resolved_surface || existing_surface || fallback_surface(provider, metadata.operation)

    status = scenario["status"]
    error = scenario["error"]

    observation = %{
      "status" => status,
      "checked_at" => checked_at,
      "mode" => mode,
      "fixtures" => fixtures,
      "failure_layer" =>
        if(status == "pass", do: nil, else: scenario["failure_layer"] || classify_failure(error)),
      "error" => error
    }

    put_surface_observation(
      surfaces,
      surface_id,
      provider,
      metadata.operation,
      scenario_id,
      metadata.proof,
      observation
    )
  end

  defp validate_surface_change!(nil, _resolved_surface, _scenario_id, _model_spec, _mode), do: :ok
  defp validate_surface_change!(_existing_surface, nil, _scenario_id, _model_spec, _mode), do: :ok

  defp validate_surface_change!(surface, surface, _scenario_id, _model_spec, _mode), do: :ok

  defp validate_surface_change!(existing, resolved, scenario_id, model_spec, "replay") do
    raise ArgumentError,
          "compatibility replay surface changed for #{model_spec} scenario #{scenario_id}: " <>
            "recorded #{existing}, replayed #{resolved}"
  end

  defp validate_surface_change!(_existing, _resolved, _scenario_id, _model_spec, _mode), do: :ok

  defp put_surface_observation(
         surfaces,
         surface_id,
         provider,
         operation,
         scenario_id,
         proof,
         observation
       ) do
    surface =
      Map.get(surfaces, surface_id, %{
        "provider" => provider,
        "operation" => Atom.to_string(operation),
        "scenarios" => %{}
      })

    scenario =
      surface
      |> Map.get("scenarios", %{})
      |> Map.get(scenario_id, %{"proof" => Atom.to_string(proof), "observations" => []})

    observations =
      scenario
      |> Map.get("observations", [])
      |> Enum.reject(&(&1["checked_at"] == observation["checked_at"]))
      |> Kernel.++([observation])
      |> Enum.sort_by(&(&1["checked_at"] || ""))

    scenarios =
      surface
      |> Map.get("scenarios", %{})
      |> Map.put(
        scenario_id,
        scenario
        |> Map.put("proof", Atom.to_string(proof))
        |> Map.put("observations", observations)
      )

    Map.put(surfaces, surface_id, Map.put(surface, "scenarios", scenarios))
  end

  defp find_scenario_surface(surfaces, scenario_id) do
    Enum.find_value(surfaces, fn {surface_id, surface} ->
      if Map.has_key?(surface["scenarios"] || %{}, scenario_id), do: surface_id
    end)
  end

  defp surface_entries(evidence, model_spec) do
    evidence
    |> get_in(["models", model_spec, "surfaces"])
    |> case do
      surfaces when is_map(surfaces) ->
        Enum.sort_by(surfaces, fn {surface_id, _} -> surface_id end)

      _ ->
        []
    end
  end

  defp surface_status(surface_id, surface, operation, opts) do
    declaration = Keyword.get(opts, :declaration, surface["declaration"] || "declared")

    if declaration == "declared" do
      evidence_surface_status(surface_id, surface, operation, opts)
    else
      declaration_status(surface_id, surface, operation, declaration)
    end
  end

  defp evidence_surface_status(surface_id, surface, operation, opts) do
    as_of = normalize_datetime(Keyword.get(opts, :as_of, DateTime.utc_now()))
    freshness_days = Keyword.get(opts, :freshness_days, @freshness_days)
    required = ScenarioCatalog.baseline_scenarios(operation)

    latest =
      surface
      |> Map.get("scenarios", %{})
      |> Map.new(fn {scenario_id, scenario} -> {scenario_id, latest_observation(scenario)} end)
      |> Map.reject(fn {_scenario_id, observation} -> is_nil(observation) end)

    required_observations = Map.take(latest, required)

    failure =
      Enum.find(required, fn scenario_id ->
        match?(%{"status" => "fail"}, required_observations[scenario_id])
      end)

    fresh_passes =
      required
      |> Enum.filter(fn scenario_id ->
        case required_observations[scenario_id] do
          %{"status" => "pass", "checked_at" => checked_at} ->
            fresh?(checked_at, as_of, freshness_days)

          _ ->
            false
        end
      end)

    missing = required -- fresh_passes
    latest_checked = latest_checked_at_from_observations(Map.values(latest))

    cond do
      required == [] ->
        status(
          :experimental,
          :no_fixture_backed_baseline,
          operation,
          required,
          missing,
          surface_id,
          checked_at: latest_checked
        )

      failure ->
        observation = required_observations[failure]

        status(:unsupported, :baseline_failure, operation, required, missing, surface_id,
          checked_at: latest_checked,
          scenario: failure,
          failure_layer: observation["failure_layer"] || "assertion"
        )

      missing == [] ->
        status(:first_class, :complete_current_baseline, operation, required, [], surface_id,
          checked_at: latest_checked
        )

      fresh_passes != [] ->
        status(:best_effort, :partial_current_baseline, operation, required, missing, surface_id,
          checked_at: latest_checked
        )

      map_size(latest) == 0 ->
        status(:experimental, :missing_evidence, operation, required, required, surface_id)

      true ->
        status(
          :experimental,
          :missing_or_stale_evidence,
          operation,
          required,
          missing,
          surface_id,
          checked_at: latest_checked
        )
    end
  end

  defp declaration_status(surface_id, surface, operation, "not_declared") do
    required = ScenarioCatalog.baseline_scenarios(operation)

    status(:unsupported, :operation_not_declared, operation, required, required, surface_id,
      checked_at: surface_latest_checked_at(surface)
    )
  end

  defp declaration_status(surface_id, surface, operation, _declaration) do
    required = ScenarioCatalog.baseline_scenarios(operation)

    status(:experimental, :surface_declaration_unknown, operation, required, required, surface_id,
      checked_at: surface_latest_checked_at(surface)
    )
  end

  defp aggregate_operation_status(operation, []) do
    required = ScenarioCatalog.baseline_scenarios(operation)
    status(:experimental, :missing_evidence, operation, required, required, nil)
  end

  defp aggregate_operation_status(_operation, statuses) do
    Enum.max_by(statuses, &tier_rank(&1.tier))
  end

  defp tier_rank(:first_class), do: 0
  defp tier_rank(:best_effort), do: 1
  defp tier_rank(:experimental), do: 2
  defp tier_rank(:unsupported), do: 3

  defp status(tier, reason, operation, required, missing, surface, extra \\ []) do
    %{
      tier: tier,
      reason: reason,
      operation: operation,
      surface: surface,
      required_scenarios: required,
      missing_scenarios: missing,
      checked_at: Keyword.get(extra, :checked_at),
      scenario: Keyword.get(extra, :scenario),
      failure_layer: Keyword.get(extra, :failure_layer)
    }
  end

  defp latest_observation(%{"observations" => observations}) when is_list(observations) do
    Enum.max_by(observations, &(&1["checked_at"] || ""), fn -> nil end)
  end

  defp latest_observation(_scenario), do: nil

  defp fresh?(nil, _as_of, _freshness_days), do: false

  defp fresh?(checked_at, as_of, freshness_days) do
    checked_at = normalize_datetime(checked_at)
    age = DateTime.diff(as_of, checked_at, :second)
    age >= 0 and age <= freshness_days * 86_400
  rescue
    _error -> false
  end

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _offset} ->
        parsed

      {:error, reason} ->
        raise ArgumentError, "invalid evidence timestamp #{inspect(datetime)}: #{reason}"
    end
  end

  defp latest_checked_at(models) do
    models
    |> Enum.flat_map(fn {_model_spec, model} ->
      model
      |> Map.get("surfaces", %{})
      |> Enum.flat_map(fn {_surface_id, surface} ->
        surface
        |> Map.get("scenarios", %{})
        |> Enum.flat_map(fn {_scenario_id, scenario} -> scenario["observations"] || [] end)
      end)
    end)
    |> latest_checked_at_from_observations()
  end

  defp latest_checked_at_from_observations(observations) do
    observations
    |> Enum.map(& &1["checked_at"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp surface_latest_checked_at(surface) do
    surface
    |> Map.get("scenarios", %{})
    |> Enum.flat_map(fn {_scenario_id, scenario} -> scenario["observations"] || [] end)
    |> latest_checked_at_from_observations()
  end

  defp scenario_metadata(scenario_id) do
    case ScenarioCatalog.fetch_scenario(scenario_id) do
      {:ok, scenario} -> scenario
      :error -> %{operation: :text, proof: :unknown}
    end
  end

  defp operation_atom!(operation) when is_binary(operation) do
    case Enum.find(ScenarioCatalog.operations(), &(Atom.to_string(&1.id) == operation)) do
      %{id: id} -> id
      nil -> raise ArgumentError, "unknown evidence operation: #{inspect(operation)}"
    end
  end

  defp declared_operations({:ok, %LLMDB.Model{} = model}) do
    operations =
      ScenarioCatalog.operations()
      |> Enum.map(& &1.id)
      |> Enum.reject(&(&1 == :all))
      |> Enum.filter(&ReqLLM.ModelOperation.supported?(model, &1))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    {"present", operations}
  end

  defp declared_operations({:error, _reason}), do: {"missing", []}

  defp surface_declaration(_operation, "missing", _declared_operations), do: "unknown"

  defp surface_declaration(operation, "present", declared_operations) do
    if operation in declared_operations, do: "declared", else: "not_declared"
  end

  defp split_model_spec(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      [model_id] -> {"unknown", model_id}
    end
  end

  defp fallback_surface(provider, operation), do: "#{provider}.unrecorded_#{operation}"
  defp default_surface_resolver(_model_spec, _operation, _fixtures), do: nil

  defp normalize_unrecorded_surface(surface_id, provider, operation) do
    if surface_id == "#{provider}.#{operation}",
      do: fallback_surface(provider, operation),
      else: surface_id
  end

  defp fixture_urls(fixture_root, provider, model_id, fixture) do
    path =
      Path.join([
        fixture_root,
        provider,
        fixture_model_dir(model_id),
        "#{fixture}.json"
      ])

    with {:ok, content} <- File.read(path),
         {:ok, fixture_data} <- Jason.decode(content) do
      fixture_request_urls(fixture_data)
    else
      _error -> []
    end
  end

  defp fixture_request_urls(%{"request" => %{"url" => url}}) when is_binary(url), do: [url]

  defp fixture_request_urls(steps) when is_list(steps) do
    Enum.flat_map(steps, &fixture_request_urls/1)
  end

  defp fixture_request_urls(_fixture_data), do: []

  defp fixture_model_dir(model_id) do
    model_id
    |> String.replace("-", "_")
    |> String.replace(".", "_")
    |> String.replace(":", "_")
    |> String.replace("/", "_")
  end

  defp surface_family(_url, operation) when operation != :text, do: Atom.to_string(operation)

  defp surface_family(url, :text) do
    path = String.downcase(URI.parse(url).path || "")

    cond do
      String.contains?(path, "/responses") -> "responses"
      String.contains?(path, "/chat/completions") -> "chat_completions"
      String.contains?(path, "/messages") -> "messages"
      String.contains?(path, "generatecontent") -> "generate_content"
      String.contains?(path, "/converse") -> "bedrock_converse"
      String.contains?(path, "/invoke") -> "bedrock_invoke"
      true -> "text"
    end
  end

  defp contains_any?(value, candidates), do: Enum.any?(candidates, &String.contains?(value, &1))

  defp scenario_fixtures(scenario) do
    scenario
    |> Map.get("observations", [])
    |> Enum.flat_map(&(&1["fixtures"] || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp merge_surface_scenario(
         surfaces,
         surface_id,
         provider,
         operation,
         scenario_id,
         scenario
       ) do
    surface =
      Map.get(surfaces, surface_id, %{
        "provider" => provider,
        "operation" => Atom.to_string(operation),
        "scenarios" => %{}
      })

    scenarios = surface["scenarios"] || %{}

    merged_scenario =
      case Map.get(scenarios, scenario_id) do
        nil -> scenario
        existing -> merge_scenario_observations(existing, scenario)
      end

    Map.put(surfaces, surface_id, %{
      surface
      | "scenarios" => Map.put(scenarios, scenario_id, merged_scenario)
    })
  end

  defp merge_scenario_observations(existing, incoming) do
    observations =
      (existing["observations"] || [])
      |> Kernel.++(incoming["observations"] || [])
      |> Enum.uniq_by(&{&1["checked_at"], &1["mode"], &1["status"]})
      |> Enum.sort_by(&(&1["checked_at"] || ""))

    existing
    |> Map.merge(incoming)
    |> Map.put("observations", observations)
  end

  defp maybe_put(map, _key, empty) when empty == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ordered(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
