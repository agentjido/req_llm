defmodule ReqLLM.Test.Scenarios do
  @moduledoc """
  Registry for provider coverage scenarios.
  """

  @default_modules [
    ReqLLM.Test.Scenarios.Basic,
    ReqLLM.Test.Scenarios.Streaming,
    ReqLLM.Test.Scenarios.TokenLimit,
    ReqLLM.Test.Scenarios.Usage,
    ReqLLM.Test.Scenarios.ContextAppend,
    ReqLLM.Test.Scenarios.ToolMulti,
    ReqLLM.Test.Scenarios.ToolRoundTrip,
    ReqLLM.Test.Scenarios.ToolNone,
    ReqLLM.Test.Scenarios.ObjectBasic,
    ReqLLM.Test.Scenarios.ObjectStreaming,
    ReqLLM.Test.Scenarios.Reasoning
  ]

  @groups %{
    core: [:basic, :usage, :token_limit],
    conversation: [:context_append],
    streaming: [:streaming],
    tools: [:tool_none, :tool_multi, :tool_round_trip],
    objects: [:object_basic, :object_streaming],
    reasoning: [:reasoning]
  }

  @spec all() :: [module()]
  def all, do: @default_modules

  @spec all([module()]) :: [module()]
  def all(modules) when is_list(modules), do: modules

  @spec ids() :: [atom()]
  def ids, do: ids(all())

  @spec ids([module()]) :: [atom()]
  def ids(modules) when is_list(modules), do: Enum.map(modules, & &1.id())

  @spec groups() :: %{atom() => [atom()]}
  def groups, do: @groups

  @spec ids_for_group(atom() | binary()) :: [atom()]
  def ids_for_group(group), do: ids_for_group(group, all())

  @spec ids_for_group(atom() | binary(), [module()]) :: [atom()]
  def ids_for_group(group, modules) when is_list(modules) do
    available = modules |> ids() |> MapSet.new()

    group
    |> normalize_id()
    |> then(&Map.get(@groups, &1, []))
    |> Enum.filter(&MapSet.member?(available, &1))
  end

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
