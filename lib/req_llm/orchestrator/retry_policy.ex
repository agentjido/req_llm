# lib/req_llm/orchestrator/retry_policy.ex
# Generated from Σ: graph/reqllm.ttl

defmodule ReqLLM.Orchestrator.RetryPolicy do
  @moduledoc """
  Policy controlling retry behavior for failed attempts.

  ## Ontology Mapping
  - RDF Class: `req:RetryPolicy`
  - Subclass of: `ex:Policy`
  """

  @type t :: %__MODULE__{
          max_attempts: non_neg_integer(),
          backoff_ms: non_neg_integer(),
          retryable_errors: [String.t()]
        }

  defstruct [
    :max_attempts,
    :backoff_ms,
    :retryable_errors
  ]

  @doc """
  Create a new retry policy with defaults.
  """
  def new(opts \\ []) do
    %__MODULE__{
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      backoff_ms: Keyword.get(opts, :backoff_ms, 1000),
      retryable_errors: Keyword.get(opts, :retryable_errors, default_retryable_errors())
    }
  end

  @doc """
  Determine if another retry attempt should be made.
  """
  def should_retry?(policy, attempts) do
    attempt_count = length(attempts)

    cond do
      attempt_count >= policy.max_attempts ->
        false

      all_attempts_failed?(attempts) ->
        last_attempt = List.last(attempts)
        is_retryable_error?(policy, last_attempt.error)

      true ->
        false
    end
  end

  @doc """
  Calculate backoff delay for the next attempt (exponential backoff).
  """
  def backoff_delay(policy, attempt_index) do
    base_delay = policy.backoff_ms
    # Exponential backoff: base * 2^(attempt_index - 1)
    round(base_delay * :math.pow(2, attempt_index - 1))
  end

  @doc """
  Check if an error is retryable according to policy.
  """
  def is_retryable_error?(policy, nil), do: false

  def is_retryable_error?(policy, error_message) do
    Enum.any?(policy.retryable_errors, fn pattern ->
      String.contains?(error_message, pattern)
    end)
  end

  # Private helpers

  defp all_attempts_failed?(attempts) do
    Enum.all?(attempts, fn attempt -> !attempt.success end)
  end

  defp default_retryable_errors do
    [
      "rate_limit",
      "timeout",
      "connection",
      "service_unavailable",
      "502",
      "503",
      "504"
    ]
  end
end
