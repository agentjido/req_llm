defmodule ReqLLM.Test.Scenarios do
  @moduledoc """
  Registry for provider coverage scenarios.
  """

  @default_modules [
    ReqLLM.Test.Scenarios.Basic,
    ReqLLM.Test.Scenarios.Streaming,
    ReqLLM.Test.Scenarios.TokenLimit,
    ReqLLM.Test.Scenarios.Usage,
    ReqLLM.Test.Scenarios.ContextAppend
  ]

  @spec all() :: [module()]
  def all, do: @default_modules

  @spec all([module()]) :: [module()]
  def all(modules) when is_list(modules), do: modules

  @spec ids() :: [atom()]
  def ids, do: ids(all())

  @spec ids([module()]) :: [atom()]
  def ids(modules) when is_list(modules), do: Enum.map(modules, & &1.id())

  @spec get(atom() | binary()) :: {:ok, module()} | :error
  def get(id), do: get(id, all())

  @spec get(atom() | binary(), [module()]) :: {:ok, module()} | :error
  def get(id, modules) when is_list(modules) do
    target = normalize_id(id)

    case Enum.find(modules, &(&1.id() == target)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @spec for_model(binary() | LLMDB.Model.t()) :: [module()]
  def for_model(model), do: for_model(model, all())

  @spec for_model(binary() | LLMDB.Model.t(), [module()]) :: [module()]
  def for_model(model, modules) when is_list(modules) do
    Enum.filter(modules, & &1.applies?(model))
  end

  @spec fixture_manifest(binary() | LLMDB.Model.t()) :: %{atom() => [binary()]}
  def fixture_manifest(model), do: fixture_manifest(model, all())

  @spec fixture_manifest(binary() | LLMDB.Model.t(), [module()]) :: %{atom() => [binary()]}
  def fixture_manifest(model, modules) when is_list(modules) do
    model
    |> for_model(modules)
    |> Map.new(fn scenario -> {scenario.id(), scenario.fixtures(model)} end)
  end

  defp normalize_id(id) when is_atom(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_atom(id)
end
