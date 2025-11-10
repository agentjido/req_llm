# lib/req_llm/orchestrator/attempt.ex
# Generated from Σ: graph/reqllm.ttl

defmodule ReqLLM.Orchestrator.Attempt do
  @moduledoc """
  A single attempt to call a specific provider.

  ## Ontology Mapping
  - RDF Class: `req:Attempt`
  - Subclass of: `ex:Event`
  """

  alias ReqLLM.Response

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          provider: String.t(),
          model: String.t(),
          cost_usd: float(),
          duration_ms: non_neg_integer(),
          success: boolean(),
          error: String.t() | nil,
          response: Response.t() | nil,
          timestamp: DateTime.t()
        }

  defstruct [
    :index,
    :provider,
    :model,
    :cost_usd,
    :duration_ms,
    :success,
    :error,
    :response,
    :timestamp
  ]

  @doc """
  Execute an attempt against a provider candidate.
  """
  def execute(candidate, context) do
    start_time = System.monotonic_time(:millisecond)
    timestamp = DateTime.utc_now()

    result =
      try do
        # Call the provider
        response = call_provider(candidate.provider, candidate.model, context)
        duration_ms = System.monotonic_time(:millisecond) - start_time

        attempt = %__MODULE__{
          index: 0,
          provider: candidate.provider,
          model: candidate.model,
          cost_usd: calculate_cost(response.usage),
          duration_ms: duration_ms,
          success: true,
          error: nil,
          response: response,
          timestamp: timestamp
        }

        {:ok, attempt}
      rescue
        error ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          attempt = %__MODULE__{
            index: 0,
            provider: candidate.provider,
            model: candidate.model,
            cost_usd: 0.0,
            duration_ms: duration_ms,
            success: false,
            error: Exception.message(error),
            response: nil,
            timestamp: timestamp
          }

          {:ok, attempt}
      end

    result
  end

  defp call_provider(provider, model, context) do
    # Delegate to existing ReqLLM functionality
    ReqLLM.generate_text(context.messages,
      provider: String.to_existing_atom(provider),
      model: model
    )
  end

  defp calculate_cost(nil), do: 0.0

  defp calculate_cost(usage) do
    Map.get(usage, :total_cost, 0.0)
  end
end
