# lib/req_llm/ontology/telemetry.ex
# Purpose: Ontology-aware telemetry integration (KNHK phase)
# Emits telemetry events with RDF metadata for observability

defmodule ReqLLM.Ontology.Telemetry do
  @moduledoc """
  Knowledge Hooks for telemetry integration.

  Emits telemetry events enriched with ontology metadata (RDF triples)
  for observability, monitoring, and semantic analysis.

  ## Events

  - `[:req_llm, :ontology, :response, :complete]` - Response completed
  - `[:req_llm, :ontology, :stream, :chunk]` - Stream chunk received
  - `[:req_llm, :ontology, :validation, :result]` - Validation performed
  - `[:req_llm, :ontology, :usage, :recorded]` - Usage metrics recorded
  - `[:req_llm, :ontology, :finish_reason, :recorded]` - FinishReason recorded

  ## Metadata

  All events include RDF metadata:
  - `ontology_type` - RDF class (e.g., "req:Response")
  - `ontology_version` - Σ hash
  - `timestamp` - ISO8601 timestamp
  """

  require Logger

  @ontology_version "2aeb94264b64"  # Current Σ hash from reqllm.version.ttl

  @doc """
  Emit telemetry event for a completed Response.

  ## Measurements
  - `input_tokens` - Input token count
  - `output_tokens` - Output token count
  - `reasoning_tokens` - Reasoning token count (if present)
  - `total_tokens` - Total token count
  - `input_cost` - Input cost in USD
  - `output_cost` - Output cost in USD
  - `total_cost` - Total cost in USD
  - `duration_ms` - Response generation duration

  ## Metadata (RDF)
  - `ontology_type: "req:Response"`
  - `ontology_version` - Σ hash
  - `finish_reason` - Stop reason (e.g., :stop, :tool_calls)
  - `provider` - LLM provider
  - `model` - Model name
  - `message_count` - Number of messages in context
  """
  def emit_response_complete(response, opts \\ []) do
    usage = get_any(response, [:usage, :stats], %{})
    context = get_any(response, [:context, :ctx], %{})
    messages = get_list(context, [:messages, :msgs], [])

    measurements = %{
      input_tokens: get_any(usage, [:input_tokens, :inputTokens], 0),
      output_tokens: get_any(usage, [:output_tokens, :outputTokens], 0),
      reasoning_tokens: get_any(usage, [:reasoning_tokens, :reasoningTokens], 0),
      total_tokens: get_any(usage, [:total_tokens, :totalTokens], 0),
      input_cost: get_any(usage, [:input_cost, :inputCost], 0.0),
      output_cost: get_any(usage, [:output_cost, :outputCost], 0.0),
      total_cost: get_any(usage, [:total_cost, :totalCost], 0.0),
      duration_ms: Keyword.get(opts, :duration_ms, 0)
    }

    metadata = %{
      ontology_type: "req:Response",
      ontology_version: @ontology_version,
      finish_reason: get_any(response, [:finish_reason, :finishReason]),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      message_count: length(messages),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :ontology, :response, :complete],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for a StreamChunk.

  ## Measurements
  - `chunk_size` - Size of chunk text in bytes
  - `chunk_index` - Index in stream

  ## Metadata (RDF)
  - `ontology_type: "req:StreamChunk"`
  - `chunk_type` - Type (:content, :thinking, :tool_call, :meta)
  """
  def emit_stream_chunk(chunk, index, opts \\ []) do
    chunk_text = get_any(chunk, [:text, :delta, :content, :chunkText])
    chunk_size = if is_binary(chunk_text), do: byte_size(chunk_text), else: 0

    measurements = %{
      chunk_size: chunk_size,
      chunk_index: index
    }

    metadata = %{
      ontology_type: "req:StreamChunk",
      ontology_version: @ontology_version,
      chunk_type: get_any(chunk, [:type, :chunk_type, :chunkType]),
      provider: Keyword.get(opts, :provider),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :ontology, :stream, :chunk],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for validation result.

  ## Measurements
  - `is_valid` - 1 if valid, 0 if invalid
  - `error_count` - Number of validation errors

  ## Metadata (RDF)
  - `ontology_type` - Type being validated
  - `validation_errors` - List of error messages
  """
  def emit_validation_result(type, result, opts \\ []) do
    {is_valid, error_count, errors} =
      case result do
        :ok -> {1, 0, []}
        {:error, errs} -> {0, length(errs), errs}
      end

    measurements = %{
      is_valid: is_valid,
      error_count: error_count
    }

    metadata = %{
      ontology_type: type,
      ontology_version: @ontology_version,
      validation_errors: errors,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :ontology, :validation, :result],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for usage metrics recording.

  Used for audit trails and cost tracking.
  """
  def emit_usage_recorded(usage, opts \\ []) do
    measurements = %{
      input_tokens: get_any(usage, [:input_tokens, :inputTokens], 0),
      output_tokens: get_any(usage, [:output_tokens, :outputTokens], 0),
      total_tokens: get_any(usage, [:total_tokens, :totalTokens], 0),
      total_cost: get_any(usage, [:total_cost, :totalCost], 0.0)
    }

    metadata = %{
      ontology_type: "req:Usage",
      ontology_version: @ontology_version,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :ontology, :usage, :recorded],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for finish reason recording.

  Used for error monitoring and quality metrics.
  """
  def emit_finish_reason_recorded(finish_reason, opts \\ []) do
    measurements = %{
      count: 1
    }

    metadata = %{
      ontology_type: "req:FinishReason",
      ontology_version: @ontology_version,
      finish_reason: finish_reason,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :ontology, :finish_reason, :recorded],
      measurements,
      metadata
    )
  end

  ##########
  # Orchestrator Telemetry (Phase 6 - Knowledge Hooks)
  ##########

  @doc """
  Emit telemetry event for CallPlan execution start.

  ## Measurements
  - `candidates_count` - Number of provider candidates

  ## Metadata (RDF)
  - `ontology_type: "req:CallPlan"`
  - `plan_id` - Unique plan identifier
  - `max_budget_usd` - Maximum budget constraint
  - `max_latency_ms` - Maximum latency constraint
  - `max_attempts` - Maximum retry attempts
  """
  def emit_call_plan_start(call_plan, opts \\ []) do
    budget = get_any(call_plan, [:budget_policy, :budgetPolicy], %{})
    retry = get_any(call_plan, [:retry_policy, :retryPolicy], %{})
    candidates = get_list(call_plan, [:candidates, :provider_candidates], [])

    measurements = %{
      candidates_count: length(candidates)
    }

    metadata = %{
      ontology_type: "req:CallPlan",
      ontology_version: @ontology_version,
      plan_id: get_any(call_plan, [:id]),
      max_budget_usd: get_any(budget, [:max_total_cost_usd, :maxTotalCostUSD]),
      max_latency_ms: get_any(budget, [:max_latency_ms, :maxLatencyMs]),
      max_attempts: get_any(retry, [:max_attempts, :maxAttempts]),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :call_plan, :start],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for CallPlan execution complete.

  ## Measurements
  - `total_cost_usd` - Total cost of all attempts
  - `total_duration_ms` - Total execution duration
  - `attempts_count` - Number of attempts made
  - `success` - 1 if succeeded, 0 if failed

  ## Metadata (RDF)
  - `ontology_type: "req:CallPlan"`
  - `plan_id` - Unique plan identifier
  - `selected_provider` - Provider that succeeded
  - `failure_reason` - Reason if failed
  """
  def emit_call_plan_complete(call_plan, result, opts \\ []) do
    attempts = get_list(call_plan, [:attempts, :attempt_history], [])
    total_cost = Enum.reduce(attempts, 0.0, fn att, acc ->
      acc + get_any(att, [:cost_usd, :actualCost], 0.0)
    end)
    total_duration = Enum.reduce(attempts, 0, fn att, acc ->
      acc + get_any(att, [:duration_ms, :durationMs], 0)
    end)

    {success, selected_provider, failure_reason} =
      case result do
        {:ok, _response} ->
          last_attempt = List.last(attempts) || %{}
          {1, get_any(last_attempt, [:provider, :providerName]), nil}
        {:error, failure} ->
          {0, nil, get_any(failure, [:reason])}
      end

    measurements = %{
      total_cost_usd: total_cost,
      total_duration_ms: total_duration,
      attempts_count: length(attempts),
      success: success
    }

    metadata = %{
      ontology_type: "req:CallPlan",
      ontology_version: @ontology_version,
      plan_id: get_any(call_plan, [:id]),
      selected_provider: selected_provider,
      failure_reason: failure_reason,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :call_plan, :complete],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for provider Attempt start.

  ## Measurements
  - `estimated_cost_usd` - Estimated cost for this attempt

  ## Metadata (RDF)
  - `ontology_type: "req:Attempt"`
  - `attempt_index` - Attempt sequence number
  - `provider_name` - Provider being attempted
  - `model_name` - Model being used
  """
  def emit_attempt_start(attempt, opts \\ []) do
    measurements = %{
      estimated_cost_usd: get_any(attempt, [:estimated_cost, :estimatedCost], 0.0)
    }

    metadata = %{
      ontology_type: "req:Attempt",
      ontology_version: @ontology_version,
      attempt_index: get_any(attempt, [:index, :sequence], 0),
      provider_name: get_any(attempt, [:provider, :providerName]),
      model_name: get_any(attempt, [:model, :modelName]),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :attempt, :start],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for provider Attempt complete.

  ## Measurements
  - `actual_cost_usd` - Actual cost of attempt
  - `duration_ms` - Duration of attempt
  - `success` - 1 if succeeded, 0 if failed

  ## Metadata (RDF)
  - `ontology_type: "req:Attempt"`
  - `attempt_index` - Attempt sequence number
  - `provider_name` - Provider attempted
  - `error_message` - Error message if failed
  """
  def emit_attempt_complete(attempt, result, opts \\ []) do
    {success, error_message} =
      case result do
        {:ok, _} -> {1, nil}
        {:error, err} -> {0, to_string(err)}
      end

    measurements = %{
      actual_cost_usd: get_any(attempt, [:cost_usd, :actualCost], 0.0),
      duration_ms: get_any(attempt, [:duration_ms, :durationMs], 0),
      success: success
    }

    metadata = %{
      ontology_type: "req:Attempt",
      ontology_version: @ontology_version,
      attempt_index: get_any(attempt, [:index, :sequence], 0),
      provider_name: get_any(attempt, [:provider, :providerName]),
      error_message: error_message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :attempt, :complete],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for budget check.

  ## Measurements
  - `current_cost_usd` - Current total cost
  - `max_cost_usd` - Maximum allowed cost
  - `remaining_budget_usd` - Remaining budget
  - `within_budget` - 1 if within budget, 0 if exceeded

  ## Metadata (RDF)
  - `ontology_type: "req:BudgetPolicy"`
  """
  def emit_budget_check(budget_policy, current_cost, opts \\ []) do
    max_cost = get_any(budget_policy, [:max_total_cost_usd, :maxTotalCostUSD], 0.0)
    remaining = max(0.0, max_cost - current_cost)
    within_budget = if current_cost <= max_cost, do: 1, else: 0

    measurements = %{
      current_cost_usd: current_cost,
      max_cost_usd: max_cost,
      remaining_budget_usd: remaining,
      within_budget: within_budget
    }

    metadata = %{
      ontology_type: "req:BudgetPolicy",
      ontology_version: @ontology_version,
      utilization_percent: if(max_cost > 0, do: (current_cost / max_cost * 100.0), else: 0.0),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :budget, :check],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for budget exceeded.

  ## Measurements
  - `total_cost_usd` - Total cost that exceeded budget
  - `max_cost_usd` - Maximum allowed cost
  - `overage_usd` - Amount over budget

  ## Metadata (RDF)
  - `ontology_type: "req:BudgetPolicy"`
  - `severity: "critical"`
  """
  def emit_budget_exceeded(budget_policy, total_cost, opts \\ []) do
    max_cost = get_any(budget_policy, [:max_total_cost_usd, :maxTotalCostUSD], 0.0)
    overage = max(0.0, total_cost - max_cost)

    measurements = %{
      total_cost_usd: total_cost,
      max_cost_usd: max_cost,
      overage_usd: overage
    }

    metadata = %{
      ontology_type: "req:BudgetPolicy",
      ontology_version: @ontology_version,
      severity: "critical",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :budget, :exceeded],
      measurements,
      metadata
    )
  end

  @doc """
  Emit telemetry event for retry decision.

  ## Measurements
  - `attempt_count` - Current attempt number
  - `max_attempts` - Maximum allowed attempts
  - `backoff_ms` - Backoff duration
  - `will_retry` - 1 if retry will occur, 0 if not

  ## Metadata (RDF)
  - `ontology_type: "req:RetryPolicy"`
  - `error_type` - Type of error encountered
  - `is_retryable` - Whether error is retryable
  """
  def emit_retry_decision(retry_policy, attempt_count, error, opts \\ []) do
    max_attempts = get_any(retry_policy, [:max_attempts, :maxAttempts], 0)
    backoff_ms = get_any(retry_policy, [:backoff_ms, :backoffMs], 0)
    will_retry = if attempt_count < max_attempts, do: 1, else: 0

    measurements = %{
      attempt_count: attempt_count,
      max_attempts: max_attempts,
      backoff_ms: backoff_ms,
      will_retry: will_retry
    }

    metadata = %{
      ontology_type: "req:RetryPolicy",
      ontology_version: @ontology_version,
      error_type: Keyword.get(opts, :error_type),
      is_retryable: Keyword.get(opts, :is_retryable, false),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute(
      [:req_llm, :orchestrator, :retry, :decision],
      measurements,
      metadata
    )
  end

  # -- Helpers --

  defp get_any(term, keys, default \\ nil) do
    data = to_map(term)
    Enum.find_value(keys, default, &Map.get(data, &1))
  end

  defp get_list(term, keys, default \\ []) do
    case get_any(term, keys) do
      nil -> default
      list when is_list(list) -> list
      one -> [one]
    end
  end

  defp to_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_map(map) when is_map(map), do: map
  defp to_map(_), do: %{}
end
