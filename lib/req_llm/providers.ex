defmodule ReqLLM.Providers do
  @moduledoc """
  Provider discovery and dispatch via introspection.

  Automatically discovers all modules implementing ReqLLM.Provider
  behaviour at startup and stores provider_id → module mapping.
  """

  @registry_key :req_llm_providers

  def initialize do
    providers = discover_providers()

    registry =
      for module <- providers,
          {:ok, provider_id} <- [get_provider_id(module)],
          into: %{} do
        {provider_id, module}
      end

    :persistent_term.put(@registry_key, registry)
    :ok
  end

  def get(provider_id) when is_atom(provider_id) do
    case :persistent_term.get(@registry_key, %{}) do
      %{^provider_id => module} -> {:ok, module}
      _ -> {:error, ReqLLM.Error.Invalid.Provider.exception(provider: provider_id)}
    end
  end

  def get!(provider_id) do
    case get(provider_id) do
      {:ok, module} -> module
      {:error, error} -> raise error
    end
  end

  def list do
    :persistent_term.get(@registry_key, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  def get_env_key(provider_id) do
    case get(provider_id) do
      {:ok, module} ->
        if function_exported?(module, :default_env_key, 0) do
          module.default_env_key()
        end

      _ ->
        nil
    end
  end

  defp discover_providers do
    {:ok, modules} = :application.get_key(:req_llm, :modules)

    Enum.filter(modules, fn module ->
      try do
        behaviours = module.__info__(:attributes)[:behaviour] || []
        ReqLLM.Provider in behaviours
      rescue
        _ -> false
      end
    end)
  end

  defp get_provider_id(module) do
    if function_exported?(module, :provider_id, 0) do
      {:ok, module.provider_id()}
    else
      module
      |> Atom.to_string()
      |> String.split(".")
      |> List.last()
      |> String.downcase()
      |> String.to_atom()
      |> then(&{:ok, &1})
    end
  rescue
    _ -> :error
  end
end
