# lib/req_llm/ontology/emitter.ex
# Purpose: Deterministic JSON-LD emitters from brownfield structs/maps, aligned with Σ and context.

defmodule ReqLLM.Ontology.Emitter do
  @moduledoc """
  Translates ReqLLM domain values (structs or maps) into JSON-LD compliant with Σ.
  Design goals:
    * Tolerant to brownfield field names (tries common aliases).
    * Includes @context only at top-level unless `:inline_context` is true.
    * Emits minimal, canonical keys that match ontologies/reqllm.context.jsonld.
  """

  alias ReqLLM.Ontology.Context, as: Ctx

  @type jsonld :: map()

  # -- Public API --------------------------------------------------------------

  @doc "Emit a Response as JSON-LD. Options: inline_context?: true|false (default false)"
  @spec emit_response(map() | struct(), keyword()) :: jsonld
  def emit_response(resp, opts \\ []) do
    top = base_node("Response", opts)
      |> put_opt_context(opts)

    top
    |> Map.put("id", get_any(resp, [:id, :response_id]))
    |> put_if("hasContext", map_if_present(get_any(resp, [:context, :ctx]), &emit_context(&1, strip: true)))
    |> put_if("hasMessageOut", map_if_present(get_any(resp, [:message, :message_out]), &emit_message(&1, strip: true)))
    |> put_if("hasUsage", map_if_present(get_any(resp, [:usage, :stats]), &emit_usage(&1, strip: true)))
    |> put_if("finishReason", enum_string(get_any(resp, [:finish_reason, :finishReason])))
  end

  @doc "Emit a Context as JSON-LD. Options: strip: omit @context when true."
  def emit_context(ctx, opts \\ []) do
    base_node("Context", opts)
    |> put_list("hasMessage", get_list(ctx, [:messages, :msgs], []), &emit_message(&1, strip: true))
    |> put_if("externalId", get_any(ctx, [:external_id, :externalId]))
  end

  @doc "Emit a Message as JSON-LD."
  def emit_message(msg, opts \\ []) do
    base_node("Message", opts)
    |> put_if("role", role_string(get_any(msg, [:role])))
    |> put_if("position", get_any(msg, [:position, :index]))
    |> put_list("hasPart", get_list(msg, [:parts, :content, :content_parts], []), &emit_part/1)
  end

  @doc "Emit a single ContentPart (TextPart, ToolCallPart, etc.)."
  def emit_part(part) do
    case part_type(part) do
      "TextPart" ->
        base_node("TextPart", strip: true)
        |> Map.put("text", get_any(part, [:text, :value, :content]))

      "ImageURLPart" ->
        base_node("ImageURLPart", strip: true)
        |> Map.put("url", get_any(part, [:url]))

      "ImagePart" ->
        base_node("ImagePart", strip: true)
        |> put_if("mediaType", get_any(part, [:media_type, :mediaType, :mime]))
        |> put_if("payload", get_any(part, [:payload, :data]))

      "FilePart" ->
        base_node("FilePart", strip: true)
        |> put_if("mediaType", get_any(part, [:media_type, :mediaType, :mime]))
        |> put_if("payload", get_any(part, [:payload, :data]))

      "ThinkingPart" ->
        base_node("ThinkingPart", strip: true)
        |> put_if("thinkingText", get_any(part, [:thinking, :text]))

      "ToolCallPart" ->
        base_node("ToolCallPart", strip: true)
        |> put_if("toolName", get_any(part, [:tool, :tool_name, :name]))
        |> put_if("argumentsJson", get_any(part, [:arguments_json, :argumentsJson, :args_json, :args]))

      "ToolResultPart" ->
        base_node("ToolResultPart", strip: true)
        |> put_if("toolCallId", get_any(part, [:tool_call_id, :toolCallId, :id]))
        |> put_if("resultJson", get_any(part, [:result_json, :resultJson, :result]))
    end
  end

  @doc "Emit a StreamChunk as JSON-LD."
  def emit_stream_chunk(chunk, opts \\ []) do
    base_node("StreamChunk", opts)
    |> put_if("chunkType", enum_string(get_any(chunk, [:type, :chunk_type, :chunkType])))
    |> put_if("chunkText", get_any(chunk, [:text, :delta, :content]))
    |> put_if("chunkMeta", get_any(chunk, [:meta, :metadata]))
  end

  @doc "Emit Usage as JSON-LD."
  def emit_usage(usage, opts \\ []) do
    base_node("Usage", opts)
    |> put_if("inputTokens", get_any(usage, [:input_tokens, :inputTokens, :prompt_tokens]))
    |> put_if("outputTokens", get_any(usage, [:output_tokens, :outputTokens, :completion_tokens]))
    |> put_if("reasoningTokens", get_any(usage, [:reasoning_tokens, :reasoningTokens]))
    |> put_if("totalTokens", get_any(usage, [:total_tokens, :totalTokens]))
    |> put_if("inputCost", get_any(usage, [:input_cost, :inputCost, :inputCostUSD]))
    |> put_if("outputCost", get_any(usage, [:output_cost, :outputCost, :outputCostUSD]))
    |> put_if("totalCost", get_any(usage, [:total_cost, :totalCost, :totalCostUSD]))
  end

  @doc "Emit CallPlan as JSON-LD."
  def emit_call_plan(plan, opts \\ []) do
    base_node("CallPlan", opts)
    |> put_if("id", get_any(plan, [:id]))
    |> put_if("hasContext", map_if_present(get_any(plan, [:context]), &emit_context(&1, strip: true)))
    |> put_list("hasCandidate", get_list(plan, [:candidates], []), &emit_provider_candidate(&1, strip: true))
    |> put_list("hasAttempt", get_list(plan, [:attempts], []), &emit_attempt(&1, strip: true))
    |> put_if("hasRetryPolicy", map_if_present(get_any(plan, [:retry_policy]), &emit_retry_policy(&1, strip: true)))
    |> put_if("hasBudgetPolicy", map_if_present(get_any(plan, [:budget_policy]), &emit_budget_policy(&1, strip: true)))
    |> put_if("hasTerminalFailure", map_if_present(get_any(plan, [:terminal_failure]), &emit_failure(&1, strip: true)))
  end

  @doc "Emit ProviderCandidate as JSON-LD."
  def emit_provider_candidate(candidate, opts \\ []) do
    base_node("ProviderCandidate", opts)
    |> put_if("priority", get_any(candidate, [:priority]))
    |> put_if("provider", get_any(candidate, [:provider]))
    |> put_if("model", get_any(candidate, [:model]))
    |> put_if("estimatedCost", get_any(candidate, [:estimated_cost, :estimatedCost]))
  end

  @doc "Emit Attempt as JSON-LD."
  def emit_attempt(attempt, opts \\ []) do
    base_node("Attempt", opts)
    |> put_if("index", get_any(attempt, [:index]))
    |> put_if("provider", get_any(attempt, [:provider]))
    |> put_if("model", get_any(attempt, [:model]))
    |> put_if("costUSD", get_any(attempt, [:cost_usd, :costUSD]))
    |> put_if("durationMs", get_any(attempt, [:duration_ms, :durationMs]))
    |> put_if("success", get_any(attempt, [:success]))
    |> put_if("error", get_any(attempt, [:error]))
    |> put_if("hasResponse", map_if_present(get_any(attempt, [:response]), &emit_response(&1, strip: true)))
    |> put_if("timestamp", format_timestamp(get_any(attempt, [:timestamp])))
  end

  @doc "Emit RetryPolicy as JSON-LD."
  def emit_retry_policy(policy, opts \\ []) do
    base_node("RetryPolicy", opts)
    |> put_if("maxAttempts", get_any(policy, [:max_attempts, :maxAttempts]))
    |> put_if("backoffMs", get_any(policy, [:backoff_ms, :backoffMs]))
    |> put_list("retryableError", get_list(policy, [:retryable_errors, :retryableErrors], []), &(&1))
  end

  @doc "Emit BudgetPolicy as JSON-LD."
  def emit_budget_policy(policy, opts \\ []) do
    base_node("BudgetPolicy", opts)
    |> put_if("maxTotalCostUSD", get_any(policy, [:max_total_cost_usd, :maxTotalCostUSD]))
    |> put_if("maxLatencyMs", get_any(policy, [:max_latency_ms, :maxLatencyMs]))
  end

  @doc "Emit Failure as JSON-LD."
  def emit_failure(failure, opts \\ []) do
    base_node("Failure", opts)
    |> put_if("reason", enum_string(get_any(failure, [:reason])))
    |> put_if("message", get_any(failure, [:message]))
    |> put_if("attemptCount", get_any(failure, [:attempt_count, :attemptCount]))
    |> put_if("totalCostUSD", get_any(failure, [:total_cost_usd, :totalCostUSD]))
    |> put_if("totalDurationMs", get_any(failure, [:total_duration_ms, :totalDurationMs]))
    |> put_if("lastError", get_any(failure, [:last_error, :lastError]))
    |> put_list("hasAttempt", get_list(failure, [:attempts], []), &emit_attempt(&1, strip: true))
    |> put_if("timestamp", format_timestamp(get_any(failure, [:timestamp])))
  end

  # -- Helpers ----------------------------------------------------------------

  # Purpose: Attach @context for top-level nodes unless stripped.
  defp put_opt_context(map, opts) do
    if Keyword.get(opts, :inline_context?, false) do
      Map.put(map, "@context", Ctx.context())
    else
      map
    end
  end

  # Purpose: Uniform node bootstrap respecting `:strip`.
  defp base_node(type, opts) do
    node = %{"@type" => type}
    if Keyword.get(opts, :strip, false), do: node, else: Map.put(node, "@context", Ctx.context())
  end

  # Purpose: Enumerations stringify to match Σ (roles, chunkType, finishReason).
  defp enum_string(nil), do: nil
  defp enum_string(v) when is_atom(v), do: Atom.to_string(v)
  defp enum_string(v) when is_binary(v), do: v

  defp role_string(v) do
    case enum_string(v) do
      "system" -> "system"
      "assistant" -> "assistant"
      "tool" -> "tool"
      _ -> "user"
    end
  end

  # Purpose: Identify content part variant from structural hints.
  defp part_type(part) do
    case enum_string(get_any(part, [:type, "@type", :variant])) do
      "TextPart" -> "TextPart"
      "ImageURLPart" -> "ImageURLPart"
      "ImagePart" -> "ImagePart"
      "FilePart" -> "FilePart"
      "ThinkingPart" -> "ThinkingPart"
      "ToolCallPart" -> "ToolCallPart"
      "ToolResultPart" -> "ToolResultPart"
      _ ->
        cond do
          get_any(part, [:arguments_json, :argumentsJson, :args_json, :args]) -> "ToolCallPart"
          get_any(part, [:result_json, :resultJson, :result]) -> "ToolResultPart"
          get_any(part, [:url]) -> "ImageURLPart"
          true -> "TextPart"
        end
    end
  end

  # Purpose: Safely pluck one of several candidate keys from struct/map.
  defp get_any(term, keys, default \\ nil) do
    data = __MODULE__.Mapify.to_map(term)
    Enum.find_value(keys, default, &Map.get(data, &1))
  end

  # Purpose: Normalize list-like fields from nil|item|list into list.
  defp get_list(term, keys, default \\ []) do
    case get_any(term, keys) do
      nil -> default
      list when is_list(list) -> list
      one -> [one]
    end
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp put_list(map, _k, [], _f), do: map
  defp put_list(map, k, list, f) when is_list(list) do
    Map.put(map, k, Enum.map(list, f))
  end

  defp map_if_present(nil, _f), do: nil
  defp map_if_present(val, f) when is_function(f, 1), do: f.(val)

  # Purpose: Format DateTime for JSON-LD (ISO8601)
  defp format_timestamp(nil), do: nil
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(ts) when is_binary(ts), do: ts

  # -- Local utility: tolerant struct→map coercion
  defmodule Mapify do
    @moduledoc false
    def to_map(%_{} = struct), do: Map.from_struct(struct)
    def to_map(map) when is_map(map), do: map
    def to_map(other), do: %{} |> Map.put(:value, other)
  end
end
