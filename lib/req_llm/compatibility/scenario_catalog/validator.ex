defmodule ReqLLM.Compatibility.ScenarioCatalog.Validator do
  @moduledoc false

  @spec validate!([map()], [map()], [map()], [map()]) :: :ok
  def validate!(operations, capabilities, scenarios, routes) do
    validate_unique_ids!(operations, :operation)
    validate_unique_ids!(capabilities, :capability)
    validate_unique_ids!(scenarios, :scenario)
    validate_operations!(operations)
    validate_capabilities!(operations, capabilities)
    validate_scenarios!(capabilities, scenarios)
    validate_routes!(scenarios, routes)
    :ok
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
      test_file = Map.fetch!(operation, :test_file)

      unless test_file == :provider_directory or
               (is_binary(test_file) and String.ends_with?(test_file, "_test.exs")) do
        raise ArgumentError, "invalid operation route: #{inspect(operation)}"
      end
    end)
  end

  defp validate_capabilities!(operations, capabilities) do
    operation_ids = MapSet.new(operations, &Map.fetch!(&1, :id))

    Enum.each(capabilities, fn capability ->
      id = Map.fetch!(capability, :id)
      operation = Map.fetch!(capability, :operation)

      unless is_binary(id) and MapSet.member?(operation_ids, operation) do
        raise ArgumentError, "invalid capability: #{inspect(capability)}"
      end
    end)
  end

  defp validate_scenarios!(capabilities, scenarios) do
    capability_ids = MapSet.new(capabilities, &Map.fetch!(&1, :id))

    Enum.each(scenarios, fn scenario ->
      id = Map.fetch!(scenario, :id)
      capability = Map.fetch!(scenario, :capability)

      unless is_binary(id) and MapSet.member?(capability_ids, capability) do
        raise ArgumentError,
              "scenario #{inspect(id)} references unknown capability #{inspect(capability)}"
      end
    end)
  end

  defp validate_routes!(scenarios, routes) do
    scenario_ids = MapSet.new(scenarios, &Map.fetch!(&1, :id))

    route_keys =
      Enum.map(routes, fn route ->
        validate_route!(route, scenario_ids)
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

  defp validate_route!(route, scenario_ids) do
    provider = Map.fetch!(route, :provider)
    scenario = Map.fetch!(route, :scenario)
    test_file = Map.fetch!(route, :test_file)

    valid? =
      is_atom(provider) and MapSet.member?(scenario_ids, scenario) and is_binary(test_file) and
        String.starts_with?(test_file, "test/coverage/") and
        String.ends_with?(test_file, "_test.exs")

    unless valid? do
      raise ArgumentError, "invalid scenario route: #{inspect(route)}"
    end
  end
end
