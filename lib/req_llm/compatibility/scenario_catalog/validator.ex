defmodule ReqLLM.Compatibility.ScenarioCatalog.Validator do
  @moduledoc false

  @operation_fields [:id, :test_file]
  @capability_fields [:id, :operation]
  @scenario_fields [
    :id,
    :capability,
    :operation,
    :input_modalities,
    :output_modalities,
    :requirements,
    :transports,
    :fixtures,
    :proof,
    :applicability,
    :providers
  ]

  @modalities [
    :audio,
    :document,
    :embedding,
    :image,
    :ranked_documents,
    :reasoning,
    :structured_object,
    :text,
    :token_logprobs,
    :tool_call,
    :tool_result,
    :usage
  ]
  @requirements [
    :cross_provider_tool_ids,
    :embedding,
    :grounding,
    :image_generation,
    :logprobs,
    :multimodal_tool_result,
    :object_generation,
    :ocr,
    :request_labels,
    :reranking,
    :speech_generation,
    :streaming_object_generation,
    :reasoning,
    :tool_calling,
    :transcription,
    :web_fetch,
    :web_search
  ]
  @transports [:request_response, :server_sent_events]
  @proofs [:declared, :fixture_replay, :live_only]
  @applicabilities [:focused, :integration, :model_features, :operation]

  @spec validate!([map()], [map()], [map()], [map()]) :: :ok
  def validate!(operations, capabilities, scenarios, routes) do
    validate_fields!(operations, @operation_fields, :operation)
    validate_fields!(capabilities, @capability_fields, :capability)
    validate_fields!(scenarios, @scenario_fields, :scenario)
    validate_unique_ids!(operations, :operation)
    validate_unique_ids!(capabilities, :capability)
    validate_unique_ids!(scenarios, :scenario)
    validate_operations!(operations)
    validate_capabilities!(operations, capabilities)
    validate_scenarios!(capabilities, scenarios)
    validate_routes!(scenarios, routes)
    :ok
  end

  defp validate_fields!(entries, expected_fields, kind) do
    expected = MapSet.new(expected_fields)

    Enum.each(entries, fn entry ->
      actual = entry |> Map.keys() |> MapSet.new()
      missing = expected |> MapSet.difference(actual) |> MapSet.to_list() |> Enum.sort()
      unknown = actual |> MapSet.difference(expected) |> MapSet.to_list() |> Enum.sort()
      id = Map.get(entry, :id, :unknown)

      if missing != [] do
        raise ArgumentError, "#{kind} #{inspect(id)} missing fields: #{inspect(missing)}"
      end

      if unknown != [] do
        raise ArgumentError, "#{kind} #{inspect(id)} has unknown fields: #{inspect(unknown)}"
      end
    end)
  end

  defp validate_unique_ids!(entries, kind) do
    duplicate_ids =
      entries
      |> Enum.map(&Map.fetch!(&1, :id))
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_ids != [] do
      raise ArgumentError, "duplicate #{kind} IDs: #{inspect(duplicate_ids)}"
    end
  end

  defp validate_operations!(operations) do
    operation_ids = Enum.map(operations, &Map.fetch!(&1, :id))

    unless operation_ids == ReqLLM.ModelOperation.operations() do
      raise ArgumentError,
            "catalog operations must match ReqLLM.ModelOperation: #{inspect(operation_ids)}"
    end

    Enum.each(operations, fn operation ->
      test_file = operation.test_file

      unless test_file == :provider_directory or
               (is_binary(test_file) and String.ends_with?(test_file, "_test.exs")) do
        raise ArgumentError, "invalid operation route: #{inspect(operation)}"
      end
    end)
  end

  defp validate_capabilities!(operations, capabilities) do
    operation_ids = MapSet.new(operations, &Map.fetch!(&1, :id))

    Enum.each(capabilities, fn capability ->
      unless is_binary(capability.id) and capability.id != "" and
               MapSet.member?(operation_ids, capability.operation) do
        raise ArgumentError, "invalid capability: #{inspect(capability)}"
      end
    end)
  end

  defp validate_scenarios!(capabilities, scenarios) do
    capabilities_by_id = Map.new(capabilities, &{&1.id, &1})

    Enum.each(scenarios, fn scenario ->
      validate_scenario!(scenario, capabilities_by_id)
    end)
  end

  defp validate_scenario!(scenario, capabilities_by_id) do
    capability = Map.get(capabilities_by_id, scenario.capability)

    unless is_binary(scenario.id) and scenario.id != "" and not is_nil(capability) do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} references unknown capability #{inspect(scenario.capability)}"
    end

    unless scenario.operation == capability.operation do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} has incompatible operation #{inspect(scenario.operation)}"
    end

    validate_enum_list!(scenario, :input_modalities, @modalities, allow_empty?: false)
    validate_enum_list!(scenario, :output_modalities, @modalities, allow_empty?: false)
    validate_enum_list!(scenario, :requirements, @requirements, allow_empty?: true)
    validate_enum_list!(scenario, :transports, @transports, allow_empty?: false)
    validate_fixtures!(scenario)
    validate_enum!(scenario, :proof, @proofs)
    validate_enum!(scenario, :applicability, @applicabilities)
    validate_providers!(scenario)

    if scenario.proof == :fixture_replay and scenario.fixtures == [] do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} is missing its fixture contract"
    end

    if scenario.applicability == :model_features and scenario.requirements == [] do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} is missing model-feature requirements"
    end
  end

  defp validate_enum_list!(scenario, field, allowed, opts) do
    value = Map.fetch!(scenario, field)
    allow_empty? = Keyword.fetch!(opts, :allow_empty?)

    valid? =
      is_list(value) and
        (allow_empty? or value != []) and
        value == Enum.uniq(value) and
        Enum.all?(value, &(&1 in allowed))

    unless valid? do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} has invalid #{field}: #{inspect(value)}"
    end
  end

  defp validate_enum!(scenario, field, allowed) do
    value = Map.fetch!(scenario, field)

    unless value in allowed do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} has invalid #{field}: #{inspect(value)}"
    end
  end

  defp validate_fixtures!(scenario) do
    fixtures = scenario.fixtures

    unless is_list(fixtures) and fixtures == Enum.uniq(fixtures) and
             Enum.all?(fixtures, &(is_binary(&1) and &1 != "" and Path.basename(&1) == &1)) do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} has invalid fixtures: #{inspect(fixtures)}"
    end
  end

  defp validate_providers!(%{providers: :all}), do: :ok

  defp validate_providers!(scenario) do
    providers = scenario.providers

    unless is_list(providers) and providers != [] and providers == Enum.uniq(providers) and
             Enum.all?(providers, &is_atom/1) do
      raise ArgumentError,
            "scenario #{inspect(scenario.id)} has invalid providers: #{inspect(providers)}"
    end
  end

  defp validate_routes!(scenarios, routes) do
    scenarios_by_id = Map.new(scenarios, &{&1.id, &1})

    route_keys =
      Enum.map(routes, fn route ->
        validate_route!(route, scenarios_by_id)
        {Map.fetch!(route, :provider), Map.fetch!(route, :scenario)}
      end)

    duplicate_routes =
      route_keys
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_routes != [] do
      raise ArgumentError, "duplicate scenario routes: #{inspect(duplicate_routes)}"
    end
  end

  defp validate_route!(route, scenarios_by_id) do
    provider = Map.fetch!(route, :provider)
    scenario_id = Map.fetch!(route, :scenario)
    test_file = Map.fetch!(route, :test_file)
    scenario = Map.get(scenarios_by_id, scenario_id)

    valid? =
      is_atom(provider) and not is_nil(scenario) and provider_applies?(scenario, provider) and
        is_binary(test_file) and String.starts_with?(test_file, "test/coverage/") and
        String.ends_with?(test_file, "_test.exs")

    unless valid? do
      raise ArgumentError, "invalid scenario route: #{inspect(route)}"
    end
  end

  defp provider_applies?(%{providers: :all}, _provider), do: true
  defp provider_applies?(scenario, provider), do: provider in scenario.providers
end
