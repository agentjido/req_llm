defmodule ReqLLM.Test.CatalogFilter do
  @moduledoc """
  Installs a temporary provider-filtered view of the loaded LLMDB catalog.
  """

  @spec allow_providers!([atom()]) :: :ok
  def allow_providers!(providers) do
    %{snapshot: snapshot, opts: opts} = LLMDB.Store.get()
    allowed = MapSet.new(providers)
    models = Enum.filter(snapshot.base_models, &MapSet.member?(allowed, &1.provider))
    filtered = LLMDB.Catalog.with_runtime_view(snapshot, models, snapshot.filters)

    ExUnit.Callbacks.on_exit(fn -> LLMDB.Store.put!(snapshot, opts) end)
    LLMDB.Store.put!(filtered, opts)
  end
end
