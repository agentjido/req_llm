# lib/req_llm/orchestrator/provider_candidate.ex
# Generated from Σ: graph/reqllm.ttl

defmodule ReqLLM.Orchestrator.ProviderCandidate do
  @moduledoc """
  A provider eligible for an attempt (ordered by priority).

  ## Ontology Mapping
  - RDF Class: `req:ProviderCandidate`
  - Subclass of: `ex:Organization`
  """

  @type t :: %__MODULE__{
          priority: non_neg_integer(),
          provider: String.t(),
          model: String.t(),
          estimated_cost: float()
        }

  defstruct [:priority, :provider, :model, :estimated_cost]

  @doc """
  Create a new provider candidate.
  """
  def new(provider, model, opts \\ []) do
    %__MODULE__{
      priority: Keyword.get(opts, :priority, 999),
      provider: provider,
      model: model,
      estimated_cost: Keyword.get(opts, :estimated_cost, 0.0)
    }
  end
end
