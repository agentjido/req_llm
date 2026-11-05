defmodule ReqLLM.Providers.CohereRerank do
  @moduledoc false

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @spec build_body(Req.Request.t()) :: map()
  def build_body(request) do
    %{
      model: request.options[:model],
      query: request.options[:query],
      documents: request.options[:documents]
    }
    |> maybe_put(:top_n, request.options[:top_n])
    |> maybe_put(:max_tokens_per_doc, request.options[:max_tokens_per_doc])
    |> maybe_put(:priority, request.options[:priority])
  end

  @spec extract_usage(term()) :: {:ok, map()} | {:error, term()}
  def extract_usage(%{"meta" => meta}) when is_map(meta) do
    tokens = Map.get(meta, "tokens") || %{}
    billed_units = Map.get(meta, "billed_units") || %{}
    search_units = Map.get(billed_units, "search_units")

    usage =
      tokens
      |> maybe_put(:billed_units, billed_units)
      |> maybe_put(:search_units, search_units)

    if usage == %{}, do: {:error, :no_usage_found}, else: {:ok, usage}
  end

  def extract_usage(_body), do: {:error, :invalid_body}
end
