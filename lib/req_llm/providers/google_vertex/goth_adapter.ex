defmodule ReqLLM.Providers.GoogleVertex.GothAdapter do
  @moduledoc false

  @token_module :"Elixir.Goth.Token"

  @dependency_error """
  Google Vertex AI authentication via Application Default Credentials
  (ADC, refresh tokens, workload identity, or the GCP metadata server)
  requires the goth dependency.
  Please add {:goth, "~> 1.4"} to your mix.exs dependencies.
  """

  def dependency_error, do: @dependency_error

  def fetch_token(config) do
    case call(@token_module, :fetch, [config]) do
      {:ok, %{__struct__: @token_module, token: token, expires: expires_at}} ->
        {:ok, %{token: token, expires_at: expires_at}}

      other ->
        other
    end
  end

  defp call(module, function, args) do
    module
    |> ensure_loaded!()
    |> apply(function, args)
  end

  defp ensure_loaded!(module) do
    case Code.ensure_loaded(module) do
      {:module, loaded_module} -> loaded_module
      {:error, _reason} -> raise @dependency_error
    end
  end
end
