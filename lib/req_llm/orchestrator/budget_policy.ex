# lib/req_llm/orchestrator/budget_policy.ex
# Generated from Σ: graph/reqllm.ttl

defmodule ReqLLM.Orchestrator.BudgetPolicy do
  @moduledoc """
  Policy controlling budget and latency constraints.

  ## Ontology Mapping
  - RDF Class: `req:BudgetPolicy`
  - Subclass of: `ex:Policy`
  """

  @type t :: %__MODULE__{
          max_total_cost_usd: float(),
          max_latency_ms: non_neg_integer()
        }

  defstruct [
    :max_total_cost_usd,
    :max_latency_ms
  ]

  @doc """
  Create a new budget policy with defaults.
  """
  def new(opts \\ []) do
    %__MODULE__{
      max_total_cost_usd: Keyword.get(opts, :max_total_cost_usd, 1.0),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, 30_000)
    }
  end

  @doc """
  Check if attempts are within budget constraints.
  """
  def within_budget?(policy, attempts) do
    total_cost = calculate_total_cost(attempts)
    total_cost <= policy.max_total_cost_usd
  end

  @doc """
  Check if total latency exceeds policy maximum.
  """
  def exceeds_latency?(policy, attempts) do
    total_latency = calculate_total_latency(attempts)
    total_latency > policy.max_latency_ms
  end

  @doc """
  Calculate remaining budget after attempts.
  """
  def remaining_budget(policy, attempts) do
    spent = calculate_total_cost(attempts)
    max(0.0, policy.max_total_cost_usd - spent)
  end

  @doc """
  Calculate remaining time budget after attempts.
  """
  def remaining_time_ms(policy, attempts) do
    spent = calculate_total_latency(attempts)
    max(0, policy.max_latency_ms - spent)
  end

  # Private helpers

  defp calculate_total_cost(attempts) do
    Enum.reduce(attempts, 0.0, fn attempt, acc ->
      acc + (attempt.cost_usd || 0.0)
    end)
  end

  defp calculate_total_latency(attempts) do
    Enum.reduce(attempts, 0, fn attempt, acc ->
      acc + (attempt.duration_ms || 0)
    end)
  end
end
