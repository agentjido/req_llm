defmodule ReqLLM.Providers.XAI.ResponseBuilder do
  @moduledoc false

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder
  alias ReqLLM.Providers.XAI.Watermark

  @impl true
  def build_response(chunks, metadata, opts) do
    provider_meta =
      metadata
      |> Map.get(:provider_meta, %{})
      |> Watermark.put_provider_metadata(Map.get(metadata, :headers, []))

    DefaultBuilder.build_response(chunks, Map.put(metadata, :provider_meta, provider_meta), opts)
  end
end
