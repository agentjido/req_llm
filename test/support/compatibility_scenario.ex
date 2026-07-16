defmodule ReqLLM.Test.CompatibilityScenario do
  @moduledoc """
  Test-side access to the compiled compatibility scenario catalog.

  Executable assertions remain in provider coverage tests. This module only
  resolves their stable tags, fixture contracts, and model applicability.
  """

  alias ReqLLM.Compatibility.ScenarioCatalog
  alias ReqLLM.ProviderTest.Comprehensive

  @spec tag!(atom()) :: [{:scenario, atom()}]
  def tag!(id) when is_atom(id) do
    ScenarioCatalog.fetch_scenario!(id)
    [scenario: id]
  end

  @spec fixture!(atom() | binary(), non_neg_integer()) :: binary()
  def fixture!(id, index \\ 0), do: ScenarioCatalog.fixture!(id, index)

  @spec applicable?(atom() | binary(), binary() | LLMDB.Model.t()) :: boolean()
  def applicable?(id, model) do
    scenario = ScenarioCatalog.fetch_scenario!(id)

    case scenario.applicability do
      :model_features -> Enum.all?(scenario.requirements, &supports?(&1, model))
      _ -> true
    end
  end

  defp supports?(:tool_calling, model), do: Comprehensive.supports_tool_calling?(model)
  defp supports?(:object_generation, model), do: Comprehensive.supports_object_generation?(model)

  defp supports?(:streaming_object_generation, model),
    do: Comprehensive.supports_streaming_object_generation?(model)

  defp supports?(:reasoning, model), do: Comprehensive.supports_reasoning?(model)
end
