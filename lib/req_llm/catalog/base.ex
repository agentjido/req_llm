defmodule ReqLLM.Catalog.Base do
  @moduledoc """
  Compile-time base catalog built from priv/models_dev/*.json.

  Recompiles when manifest changes (updated by mix req_llm.model_sync).
  """

  @manifest Path.expand("../../../priv/models_dev/.catalog_manifest.json", __DIR__)
  @external_resource @manifest

  {files, _hash} =
    if File.exists?(@manifest) do
      manifest = @manifest |> File.read!() |> Jason.decode!()
      {manifest["files"] || [], manifest["hash"] || ""}
    else
      {[], ""}
    end

  Enum.each(files, &Module.put_attribute(__MODULE__, :external_resource, &1))

  @base_catalog (
                  normalize = fn
                    %{"provider" => prov, "models" => models} when is_list(models) ->
                      models_map = Map.new(models, fn %{"id" => id} = m -> {id, m} end)
                      Map.put(prov, "models", models_map)

                    data ->
                      data
                  end

                  files
                  |> Enum.map(fn file -> file |> File.read!() |> Jason.decode!() end)
                  |> Enum.map(normalize)
                  |> Map.new(fn provider -> {provider["id"], provider} end)
                )

  @doc "Returns the normalized base catalog (compiled at build time)"
  @spec base() :: map()
  def base, do: @base_catalog
end
