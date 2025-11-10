# lib/req_llm/ontology/validator.ex
# Purpose: Elixir-based SHACL-inspired validation for runtime checks

defmodule ReqLLM.Ontology.Validator do
  @moduledoc """
  Runtime semantic validation based on SHACL constraints.
  Validates JSON-LD emitted structures against ontology invariants (Σ + Q).

  This is a lightweight Elixir implementation of key SHACL constraints
  for runtime validation. For full SHACL compliance, use Apache Jena validator.
  """


  @type validation_result :: :ok | {:error, [String.t()]}

  @doc """
  Validate a Response struct/map against SHACL constraints.
  Returns :ok or {:error, [error_messages]}.
  """
  @spec validate_response(map() | struct()) :: validation_result
  def validate_response(resp) do
    errors = []

    # Must have context
    errors =
      if get_any(resp, [:context, :ctx]) == nil do
        ["Response must have context" | errors]
      else
        errors
      end

    # Must have message
    errors =
      if get_any(resp, [:message, :message_out]) == nil do
        ["Response must have message" | errors]
      else
        errors
      end

    # Must have valid finishReason
    finish_reason = get_any(resp, [:finish_reason, :finishReason])

    errors =
      if finish_reason not in [:stop, :length, :tool_calls, :content_filter, :error, "stop", "length", "tool_calls", "content_filter", "error"] do
        ["Response finishReason must be one of: stop, length, tool_calls, content_filter, error" | errors]
      else
        errors
      end

    # Validate nested context if present
    errors =
      case get_any(resp, [:context, :ctx]) do
        nil -> errors
        ctx -> validate_context(ctx) |> merge_errors(errors)
      end

    # Validate nested message if present
    errors =
      case get_any(resp, [:message, :message_out]) do
        nil -> errors
        msg -> validate_message(msg) |> merge_errors(errors)
      end

    # Validate usage if present
    errors =
      case get_any(resp, [:usage, :stats]) do
        nil -> errors
        usage -> validate_usage(usage) |> merge_errors(errors)
      end

    to_result(errors)
  end

  @doc "Validate a Context"
  @spec validate_context(map() | struct()) :: validation_result
  def validate_context(ctx) do
    errors = []

    # Must have at least one message
    messages = get_list(ctx, [:messages, :msgs], [])

    errors =
      if Enum.empty?(messages) do
        ["Context must have at least one message" | errors]
      else
        errors
      end

    # Validate each message
    errors =
      messages
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {msg, idx}, acc ->
        case validate_message(msg) do
          :ok -> acc
          {:error, msg_errors} ->
            Enum.map(msg_errors, &"Message[#{idx}]: #{&1}") ++ acc
        end
      end)

    to_result(errors)
  end

  @doc "Validate a Message"
  @spec validate_message(map() | struct()) :: validation_result
  def validate_message(msg) do
    errors = []

    # Must have role
    role = get_any(msg, [:role])

    errors =
      if role == nil do
        ["Message must have role" | errors]
      else
        errors
      end

    # Role must be valid
    errors =
      if role not in [:system, :user, :assistant, :tool, "system", "user", "assistant", "tool"] do
        ["Message role must be one of: system, user, assistant, tool" | errors]
      else
        errors
      end

    # Must have at least one part
    parts = get_list(msg, [:parts, :content, :content_parts], [])

    errors =
      if Enum.empty?(parts) do
        ["Message must have at least one content part" | errors]
      else
        errors
      end

    # Validate each part
    errors =
      parts
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {part, idx}, acc ->
        case validate_part(part) do
          :ok -> acc
          {:error, part_errors} ->
            Enum.map(part_errors, &"Part[#{idx}]: #{&1}") ++ acc
        end
      end)

    # Position must be non-negative if present
    errors =
      case get_any(msg, [:position, :index]) do
        nil -> errors
        pos when is_integer(pos) and pos >= 0 -> errors
        _ -> ["Message position must be a non-negative integer" | errors]
      end

    to_result(errors)
  end

  @doc "Validate a ContentPart"
  @spec validate_part(map() | struct()) :: validation_result
  def validate_part(part) do
    type = part_type(part)

    case type do
      "TextPart" ->
        validate_text_part(part)

      "ImageURLPart" ->
        validate_image_url_part(part)

      "ImagePart" ->
        validate_image_part(part)

      "FilePart" ->
        validate_file_part(part)

      "ThinkingPart" ->
        validate_thinking_part(part)

      "ToolCallPart" ->
        validate_tool_call_part(part)

      "ToolResultPart" ->
        validate_tool_result_part(part)

      _ ->
        {:error, ["Unknown part type: #{type}"]}
    end
  end

  @doc "Validate Usage metrics"
  @spec validate_usage(map() | struct()) :: validation_result
  def validate_usage(usage) do
    errors = []

    # inputTokens must be non-negative if present
    errors = validate_non_negative_int(usage, [:input_tokens, :inputTokens], "inputTokens", errors)

    # outputTokens must be non-negative if present
    errors = validate_non_negative_int(usage, [:output_tokens, :outputTokens], "outputTokens", errors)

    # reasoningTokens must be non-negative if present
    errors = validate_non_negative_int(usage, [:reasoning_tokens, :reasoningTokens], "reasoningTokens", errors)

    # totalTokens must be non-negative if present
    errors = validate_non_negative_int(usage, [:total_tokens, :totalTokens], "totalTokens", errors)

    # Costs must be non-negative if present
    errors = validate_non_negative_decimal(usage, [:input_cost, :inputCost], "inputCost", errors)
    errors = validate_non_negative_decimal(usage, [:output_cost, :outputCost], "outputCost", errors)
    errors = validate_non_negative_decimal(usage, [:total_cost, :totalCost], "totalCost", errors)

    to_result(errors)
  end

  ##########
  # Orchestrator Validation (Phase 2 - Budget-Aware Failover)
  ##########

  @doc "Validate BudgetPolicy constraints"
  @spec validate_budget_policy(map() | struct()) :: validation_result
  def validate_budget_policy(policy) do
    errors = []

    # maxTotalCostUSD must be between 0 and 100
    max_cost = get_any(policy, [:max_total_cost_usd, :maxTotalCostUSD])
    errors =
      cond do
        max_cost == nil ->
          ["BudgetPolicy must have maxTotalCostUSD" | errors]
        not is_number(max_cost) ->
          ["BudgetPolicy maxTotalCostUSD must be a number" | errors]
        max_cost <= 0.0 ->
          ["BudgetPolicy maxTotalCostUSD must be > 0 USD" | errors]
        max_cost > 100.0 ->
          ["BudgetPolicy maxTotalCostUSD must be <= 100 USD" | errors]
        true -> errors
      end

    # maxLatencyMs must be between 0 and 300000
    max_latency = get_any(policy, [:max_latency_ms, :maxLatencyMs])
    errors =
      cond do
        max_latency == nil ->
          ["BudgetPolicy must have maxLatencyMs" | errors]
        not is_integer(max_latency) ->
          ["BudgetPolicy maxLatencyMs must be an integer" | errors]
        max_latency <= 0 ->
          ["BudgetPolicy maxLatencyMs must be > 0 ms" | errors]
        max_latency > 300_000 ->
          ["BudgetPolicy maxLatencyMs must be <= 300000 ms (5 minutes)" | errors]
        true -> errors
      end

    to_result(errors)
  end

  @doc "Validate RetryPolicy constraints"
  @spec validate_retry_policy(map() | struct()) :: validation_result
  def validate_retry_policy(policy) do
    errors = []

    # maxAttempts must be between 1 and 10
    max_attempts = get_any(policy, [:max_attempts, :maxAttempts])
    errors =
      cond do
        max_attempts == nil ->
          ["RetryPolicy must have maxAttempts" | errors]
        not is_integer(max_attempts) ->
          ["RetryPolicy maxAttempts must be an integer" | errors]
        max_attempts < 1 ->
          ["RetryPolicy maxAttempts must be >= 1" | errors]
        max_attempts > 10 ->
          ["RetryPolicy maxAttempts must be <= 10" | errors]
        true -> errors
      end

    # backoffMs must be between 100 and 60000
    backoff_ms = get_any(policy, [:backoff_ms, :backoffMs])
    errors =
      cond do
        backoff_ms == nil ->
          ["RetryPolicy must have backoffMs" | errors]
        not is_integer(backoff_ms) ->
          ["RetryPolicy backoffMs must be an integer" | errors]
        backoff_ms < 100 ->
          ["RetryPolicy backoffMs must be >= 100 ms" | errors]
        backoff_ms > 60_000 ->
          ["RetryPolicy backoffMs must be <= 60000 ms (1 minute)" | errors]
        true -> errors
      end

    # backoffMultiplier must be >= 1.0 if present
    case get_any(policy, [:backoff_multiplier, :backoffMultiplier]) do
      nil -> to_result(errors)
      mult when is_number(mult) and mult >= 1.0 -> to_result(errors)
      _ -> to_result(["RetryPolicy backoffMultiplier must be >= 1.0" | errors])
    end
  end

  @doc "Validate ProviderCandidate constraints"
  @spec validate_provider_candidate(map() | struct()) :: validation_result
  def validate_provider_candidate(candidate) do
    errors = []

    # providerName is required
    provider_name = get_any(candidate, [:provider_name, :providerName, :name])
    errors =
      if provider_name == nil or (is_binary(provider_name) and String.length(provider_name) == 0) do
        ["ProviderCandidate must have non-empty providerName" | errors]
      else
        errors
      end

    # priority must be between 0 and 999
    priority = get_any(candidate, [:priority])
    errors =
      cond do
        priority == nil ->
          ["ProviderCandidate must have priority" | errors]
        not is_integer(priority) ->
          ["ProviderCandidate priority must be an integer" | errors]
        priority < 0 ->
          ["ProviderCandidate priority must be >= 0" | errors]
        priority > 999 ->
          ["ProviderCandidate priority must be <= 999" | errors]
        true -> errors
      end

    # estimatedCost must be non-negative if present
    errors = validate_non_negative_decimal(candidate, [:estimated_cost, :estimatedCost], "estimatedCost", errors)

    to_result(errors)
  end

  @doc "Validate CallPlan constraints"
  @spec validate_call_plan(map() | struct()) :: validation_result
  def validate_call_plan(plan) do
    errors = []

    # Must have BudgetPolicy
    budget_policy = get_any(plan, [:budget_policy, :budgetPolicy])
    errors =
      if budget_policy == nil do
        ["CallPlan must have budgetPolicy" | errors]
      else
        errors
      end

    # Must have RetryPolicy
    retry_policy = get_any(plan, [:retry_policy, :retryPolicy])
    errors =
      if retry_policy == nil do
        ["CallPlan must have retryPolicy" | errors]
      else
        errors
      end

    # Must have Context
    context = get_any(plan, [:context, :ctx])
    errors =
      if context == nil do
        ["CallPlan must have context" | errors]
      else
        errors
      end

    # Must have at least one candidate
    candidates = get_list(plan, [:candidates, :provider_candidates], [])
    errors =
      if Enum.empty?(candidates) do
        ["CallPlan must have at least one candidate" | errors]
      else
        errors
      end

    # Validate nested policies if present
    errors =
      if budget_policy != nil do
        validate_budget_policy(budget_policy) |> merge_errors(errors)
      else
        errors
      end

    errors =
      if retry_policy != nil do
        validate_retry_policy(retry_policy) |> merge_errors(errors)
      else
        errors
      end

    # Validate all candidates
    errors =
      candidates
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {candidate, idx}, acc ->
        case validate_provider_candidate(candidate) do
          :ok -> acc
          {:error, cand_errors} ->
            Enum.map(cand_errors, &"Candidate[#{idx}]: #{&1}") ++ acc
        end
      end)

    to_result(errors)
  end

  @doc "Validate Attempt constraints"
  @spec validate_attempt(map() | struct()) :: validation_result
  def validate_attempt(attempt) do
    errors = []

    # sequence must be non-negative
    errors = validate_non_negative_int(attempt, [:sequence], "sequence", errors)

    # providerName is required
    provider_name = get_any(attempt, [:provider_name, :providerName])
    errors =
      if provider_name == nil or (is_binary(provider_name) and String.length(provider_name) == 0) do
        ["Attempt must have non-empty providerName" | errors]
      else
        errors
      end

    # startedAtMs must be non-negative if present
    errors = validate_non_negative_int(attempt, [:started_at_ms, :startedAtMs], "startedAtMs", errors)

    # durationMs must be non-negative if present
    errors = validate_non_negative_int(attempt, [:duration_ms, :durationMs], "durationMs", errors)

    to_result(errors)
  end

  @doc "Validate Failure constraints"
  @spec validate_failure(map() | struct()) :: validation_result
  def validate_failure(failure) do
    errors = []

    # reason is required
    reason = get_any(failure, [:reason])
    errors =
      if reason == nil or (is_binary(reason) and String.length(reason) == 0) do
        ["Failure must have non-empty reason" | errors]
      else
        errors
      end

    # retryable is required boolean
    retryable = get_any(failure, [:retryable])
    errors =
      if retryable == nil or not is_boolean(retryable) do
        ["Failure must have retryable (true/false)" | errors]
      else
        errors
      end

    # timestampMs must be non-negative if present
    errors = validate_non_negative_int(failure, [:timestamp_ms, :timestampMs], "timestampMs", errors)

    to_result(errors)
  end

  @doc """
  Deep validation for CallPlan including budget consistency check.

  Checks:
  - All CallPlan constraints
  - At least one candidate with estimatedCost <= maxTotalCostUSD
  - Warning: High retry attempts (>5) with strict budget (<$1)
  """
  @spec validate_call_plan_deep(map() | struct()) :: validation_result
  def validate_call_plan_deep(plan) do
    # First validate basic CallPlan constraints
    case validate_call_plan(plan) do
      {:error, _} = err -> err
      :ok ->
        errors = []

        # Budget consistency: at least one affordable candidate
        budget_policy = get_any(plan, [:budget_policy, :budgetPolicy])
        candidates = get_list(plan, [:candidates, :provider_candidates], [])

        errors =
          if budget_policy != nil and not Enum.empty?(candidates) do
            max_cost = get_any(budget_policy, [:max_total_cost_usd, :maxTotalCostUSD])
            affordable? = Enum.any?(candidates, fn cand ->
              case get_any(cand, [:estimated_cost, :estimatedCost]) do
                nil -> false
                cost when is_number(cost) -> cost <= max_cost
                _ -> false
              end
            end)

            if not affordable? do
              ["CallPlan: No candidate has estimatedCost <= maxTotalCostUSD (#{max_cost})" | errors]
            else
              errors
            end
          else
            errors
          end

        # Warning: High retry + strict budget
        retry_policy = get_any(plan, [:retry_policy, :retryPolicy])
        errors =
          if budget_policy != nil and retry_policy != nil do
            max_attempts = get_any(retry_policy, [:max_attempts, :maxAttempts])
            max_cost = get_any(budget_policy, [:max_total_cost_usd, :maxTotalCostUSD])

            if is_integer(max_attempts) and max_attempts > 5 and
               is_number(max_cost) and max_cost < 1.0 do
              ["CallPlan Warning: High retry attempts (#{max_attempts}) with strict budget ($#{max_cost}) may cause premature failure" | errors]
            else
              errors
            end
          else
            errors
          end

        to_result(errors)
    end
  end

  # -- Private Helpers --

  defp validate_text_part(part) do
    text = get_any(part, [:text, :value, :content])

    if text == nil or (is_binary(text) and String.length(text) == 0) do
      {:error, ["TextPart must have non-empty text"]}
    else
      :ok
    end
  end

  defp validate_image_url_part(part) do
    url = get_any(part, [:url])

    if url == nil or (is_binary(url) and String.length(url) == 0) do
      {:error, ["ImageURLPart must have url"]}
    else
      :ok
    end
  end

  defp validate_image_part(part) do
    errors = []

    media_type = get_any(part, [:media_type, :mediaType, :mime])
    errors = if media_type == nil, do: ["ImagePart must have mediaType" | errors], else: errors
    errors =
      if media_type != nil and is_binary(media_type) and not String.starts_with?(media_type, "image/") do
        ["ImagePart mediaType must start with 'image/'" | errors]
      else
        errors
      end

    payload = get_any(part, [:payload, :data])
    errors = if payload == nil, do: ["ImagePart must have payload" | errors], else: errors

    to_result(errors)
  end

  defp validate_file_part(part) do
    errors = []

    media_type = get_any(part, [:media_type, :mediaType, :mime])
    errors = if media_type == nil, do: ["FilePart must have mediaType" | errors], else: errors

    payload = get_any(part, [:payload, :data])
    errors = if payload == nil, do: ["FilePart must have payload" | errors], else: errors

    to_result(errors)
  end

  defp validate_thinking_part(part) do
    thinking = get_any(part, [:thinking, :text, :thinkingText])

    if thinking == nil do
      {:error, ["ThinkingPart must have thinkingText"]}
    else
      :ok
    end
  end

  defp validate_tool_call_part(part) do
    errors = []

    tool_name = get_any(part, [:tool, :tool_name, :name, :toolName])
    errors = if tool_name == nil or (is_binary(tool_name) and String.length(tool_name) == 0),
      do: ["ToolCallPart must have non-empty toolName" | errors],
      else: errors

    args = get_any(part, [:arguments_json, :argumentsJson, :args_json, :args])
    errors = if args == nil, do: ["ToolCallPart must have argumentsJson" | errors], else: errors

    to_result(errors)
  end

  defp validate_tool_result_part(part) do
    errors = []

    tool_call_id = get_any(part, [:tool_call_id, :toolCallId, :id])
    errors = if tool_call_id == nil, do: ["ToolResultPart must have toolCallId" | errors], else: errors

    result = get_any(part, [:result_json, :resultJson, :result])
    errors = if result == nil, do: ["ToolResultPart must have resultJson" | errors], else: errors

    to_result(errors)
  end

  defp validate_non_negative_int(map, keys, name, errors) do
    case get_any(map, keys) do
      nil -> errors
      val when is_integer(val) and val >= 0 -> errors
      _ -> ["Usage #{name} must be a non-negative integer" | errors]
    end
  end

  defp validate_non_negative_decimal(map, keys, name, errors) do
    case get_any(map, keys) do
      nil -> errors
      val when is_number(val) and val >= 0 -> errors
      _ -> ["Usage #{name} must be a non-negative number" | errors]
    end
  end

  defp part_type(part) do
    # Same logic as Emitter but handling both atom and string types
    case enum_string(get_any(part, [:type, "@type", :variant])) do
      type when type in ["TextPart", "text"] -> "TextPart"
      type when type in ["ImageURLPart", "image_url"] -> "ImageURLPart"
      type when type in ["ImagePart", "image"] -> "ImagePart"
      type when type in ["FilePart", "file"] -> "FilePart"
      type when type in ["ThinkingPart", "thinking"] -> "ThinkingPart"
      type when type in ["ToolCallPart", "tool_call"] -> "ToolCallPart"
      type when type in ["ToolResultPart", "tool_result"] -> "ToolResultPart"
      _ ->
        cond do
          get_any(part, [:arguments_json, :argumentsJson, :args_json, :args]) -> "ToolCallPart"
          get_any(part, [:result_json, :resultJson, :result]) -> "ToolResultPart"
          get_any(part, [:url]) -> "ImageURLPart"
          get_any(part, [:media_type, :mediaType, :mime]) && get_any(part, [:payload, :data]) ->
            media_type = get_any(part, [:media_type, :mediaType, :mime]) || ""
            if is_binary(media_type) and String.starts_with?(media_type, "image/") do
              "ImagePart"
            else
              "FilePart"
            end
          true -> "TextPart"
        end
    end
  end

  defp enum_string(nil), do: nil
  defp enum_string(v) when is_atom(v), do: Atom.to_string(v)
  defp enum_string(v) when is_binary(v), do: v

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

  defp to_result([]), do: :ok
  defp to_result(errors), do: {:error, Enum.reverse(errors)}

  defp merge_errors(:ok, acc), do: acc
  defp merge_errors({:error, errors}, acc), do: errors ++ acc
end
