defmodule ReqLLM.RerankResponse do
  @moduledoc """
  Canonical reranking response for ReqLLM.

  Results are ordered from most relevant to least relevant and include the
  original document text for convenience.
  """

  @type result_item :: %{
          required(:index) => non_neg_integer(),
          required(:relevance_score) => float(),
          required(:document) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          query: String.t(),
          results: [result_item()],
          meta: map() | nil
        }

  defstruct [:id, :model, :query, :meta, results: []]
end
