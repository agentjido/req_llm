defmodule ReqLLM.ProviderDispatch do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.CatalogGateway

  @spec get(LLMDB.Model.t(), :chat | :object, keyword()) ::
          {:ok, module()} | {:error, Exception.t()}
  def get(%LLMDB.Model{} = model, operation, opts \\ []) do
    case ReqLLM.Providers.get(model.provider) do
      {:ok, provider_module} ->
        {:ok, provider_module}

      {:error, _} ->
        case CatalogGateway.contract(model, operation, opts) do
          {:ok, _contract} -> {:ok, CatalogGateway}
          {:error, error} -> {:error, error}
        end
    end
  end

  @spec unsupported(LLMDB.Model.t(), atom(), String.t()) :: {:error, Exception.t()}
  def unsupported(model, operation, reason) do
    {:error,
     Parameter.exception(
       parameter:
         "#{model.provider}:#{model.id} cannot run #{operation} through the catalog gateway: #{reason}"
     )}
  end
end
