# lib/req_llm/orchestrator/failure.ex
# Generated from Σ: graph/reqllm.ttl

defmodule ReqLLM.Orchestrator.Failure do
  @moduledoc """
  Terminal failure when all retry attempts exhausted.

  ## Ontology Mapping
  - RDF Class: `req:Failure`
  - Subclass of: `ex:Event`
  """

  alias ReqLLM.Orchestrator.Attempt

  @type t :: %__MODULE__{
          reason: atom(),
          message: String.t(),
          attempt_count: non_neg_integer(),
          total_cost_usd: float(),
          total_duration_ms: non_neg_integer(),
          last_error: String.t() | nil,
          attempts: [Attempt.t()],
          timestamp: DateTime.t()
        }

  defstruct [
    :reason,
    :message,
    :attempt_count,
    :total_cost_usd,
    :total_duration_ms,
    :last_error,
    :attempts,
    :timestamp
  ]

  @doc """
  Create a failure from a list of attempts.
  """
  def from_attempts(attempts, reason \\ :all_attempts_failed) do
    last_attempt = List.last(attempts)

    %__MODULE__{
      reason: reason,
      message: build_message(reason, attempts),
      attempt_count: length(attempts),
      total_cost_usd: sum_costs(attempts),
      total_duration_ms: sum_durations(attempts),
      last_error: last_attempt && last_attempt.error,
      attempts: attempts,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Convert failure to standard error tuple.
  """
  def to_error(failure) do
    {:error, %{
      type: :orchestration_failure,
      reason: failure.reason,
      message: failure.message,
      metadata: %{
        attempt_count: failure.attempt_count,
        total_cost_usd: failure.total_cost_usd,
        total_duration_ms: failure.total_duration_ms,
        last_error: failure.last_error
      }
    }}
  end

  @doc """
  Create failure from budget exhaustion.
  """
  def budget_exceeded(attempts, max_budget) do
    actual_cost = sum_costs(attempts)

    from_attempts(attempts, :budget_exceeded)
    |> Map.put(:message, "Budget exceeded: spent $#{actual_cost} of $#{max_budget}")
  end

  @doc """
  Create failure from latency timeout.
  """
  def latency_exceeded(attempts, max_latency_ms) do
    actual_latency = sum_durations(attempts)

    from_attempts(attempts, :latency_exceeded)
    |> Map.put(:message, "Latency exceeded: #{actual_latency}ms of #{max_latency_ms}ms")
  end

  @doc """
  Create failure when no more candidates available.
  """
  def no_candidates_available(attempts) do
    from_attempts(attempts, :no_candidates)
    |> Map.put(:message, "No more provider candidates available")
  end

  # Private helpers

  defp build_message(:all_attempts_failed, attempts) do
    count = length(attempts)
    "All #{count} attempt(s) failed"
  end

  defp build_message(:budget_exceeded, _attempts) do
    "Budget limit exceeded"
  end

  defp build_message(:latency_exceeded, _attempts) do
    "Latency limit exceeded"
  end

  defp build_message(:no_candidates, _attempts) do
    "No provider candidates available"
  end

  defp build_message(reason, attempts) do
    "Orchestration failed: #{reason} after #{length(attempts)} attempt(s)"
  end

  defp sum_costs(attempts) do
    Enum.reduce(attempts, 0.0, fn attempt, acc ->
      acc + (attempt.cost_usd || 0.0)
    end)
  end

  defp sum_durations(attempts) do
    Enum.reduce(attempts, 0, fn attempt, acc ->
      acc + (attempt.duration_ms || 0)
    end)
  end
end
