# lib/req_llm/orchestrator/call_plan.ex
# Generated from Σ: graph/reqllm.ttl
# Purpose: Multi-provider orchestration with budget/latency constraints

defmodule ReqLLM.Orchestrator.CallPlan do
  @moduledoc """
  Orchestration plan for multi-provider LLM calls with failover.

  Implements budget-aware provider selection with automatic fallback.

  ## Ontology Mapping
  - RDF Class: `req:CallPlan`
  - Subclass of: `ex:Process`
  - Properties: `plansForContext`, `hasCandidate`, `hasAttempt`, `appliesRetry`, `appliesBudget`
  """

  alias ReqLLM.{Context, Response}
  alias ReqLLM.Orchestrator.{ProviderCandidate, Attempt, RetryPolicy, BudgetPolicy, Failure}

  @type t :: %__MODULE__{
          id: String.t(),
          context: Context.t(),
          candidates: [ProviderCandidate.t()],
          attempts: [Attempt.t()],
          retry_policy: RetryPolicy.t(),
          budget_policy: BudgetPolicy.t(),
          terminal_failure: Failure.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :context,
    :candidates,
    :attempts,
    :retry_policy,
    :budget_policy,
    :terminal_failure,
    :created_at,
    :updated_at
  ]

  @doc """
  Create a new CallPlan from context and policies.

  ## Examples

      iex> candidates = [
      ...>   %ProviderCandidate{priority: 0, provider: "openai", model: "gpt-4"},
      ...>   %ProviderCandidate{priority: 1, provider: "anthropic", model: "claude-3-opus"}
      ...> ]
      iex> {:ok, plan} = CallPlan.new(context, candidates, retry_policy, budget_policy)
  """
  def new(context, candidates, retry_policy, budget_policy) do
    now = DateTime.utc_now()

    plan = %__MODULE__{
      id: "plan_" <> Uniq.UUID.uuid4(),
      context: context,
      candidates: Enum.sort_by(candidates, & &1.priority),
      attempts: [],
      retry_policy: retry_policy,
      budget_policy: budget_policy,
      created_at: now,
      updated_at: now
    }

    {:ok, plan}
  end

  @doc """
  Execute the call plan with automatic failover.

  Returns `{:ok, response}` on success or `{:error, failure}` after exhausting all attempts.
  """
  def execute(plan) do
    with {:ok, candidate} <- select_next_candidate(plan),
         {:ok, attempt} <- Attempt.execute(candidate, plan.context),
         {:ok, plan} <- record_attempt(plan, attempt) do
      case attempt.success do
        true ->
          {:ok, attempt.response}

        false ->
          if should_retry?(plan) do
            execute(plan)
          else
            failure = build_terminal_failure(plan)
            {:error, failure}
          end
      end
    end
  end

  @doc """
  Select the next provider candidate based on priority and budget.
  """
  def select_next_candidate(plan) do
    attempted_providers =
      plan.attempts
      |> Enum.map(& &1.provider)
      |> MapSet.new()

    plan.candidates
    |> Enum.reject(&MapSet.member?(attempted_providers, &1.provider))
    |> Enum.find(&within_budget?(&1, plan))
    |> case do
      nil -> {:error, :no_candidates_available}
      candidate -> {:ok, candidate}
    end
  end

  defp within_budget?(candidate, plan) do
    current_cost = total_cost(plan)
    estimated_total = current_cost + candidate.estimated_cost

    estimated_total <= plan.budget_policy.max_total_cost_usd
  end

  defp should_retry?(plan) do
    length(plan.attempts) < plan.retry_policy.max_attempts
  end

  defp total_cost(plan) do
    plan.attempts
    |> Enum.map(& &1.cost_usd)
    |> Enum.sum()
  end

  defp record_attempt(plan, attempt) do
    plan = %{plan | attempts: plan.attempts ++ [attempt], updated_at: DateTime.utc_now()}
    {:ok, plan}
  end

  defp build_terminal_failure(plan) do
    Failure.from_attempts(plan.attempts, :all_attempts_failed)
  end
end
