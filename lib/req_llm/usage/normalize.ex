defmodule ReqLLM.Usage.Normalize do
  @moduledoc false

  alias ReqLLM.MapAccess
  alias ReqLLM.Usage.Image
  alias ReqLLM.Usage.Tool

  @spec tool_usage(any()) :: map()
  def tool_usage(usage), do: Tool.normalize(usage)

  @spec image_usage(any()) :: map()
  def image_usage(usage), do: Image.normalize(usage)

  @spec normalize(map()) :: map()
  def normalize(usage) when is_map(usage) do
    input_includes_cached = detect_input_includes_cached(usage)

    input =
      (first_present(usage, [
         :input,
         "input",
         :prompt_tokens,
         "prompt_tokens",
         :input_tokens,
         "input_tokens"
       ]) || 0)
      |> normalize_counter()

    output =
      (first_present(usage, [
         :output,
         "output",
         :completion_tokens,
         "completion_tokens",
         :output_tokens,
         "output_tokens"
       ]) || 0)
      |> normalize_counter()

    reasoning =
      (first_present(usage, [:reasoning, "reasoning", :reasoning_tokens, "reasoning_tokens"]) ||
         get_reasoning_tokens(usage))
      |> normalize_counter()

    cached_input = get_cached_input_tokens(usage, input, input_includes_cached)
    cache_creation = get_cache_creation_tokens(usage, input, input_includes_cached)
    cache_write_tokens_by_ttl = cache_write_groups(usage)
    total_tokens = total_tokens_from_usage(usage, input, output)

    canonical = %{
      billing_usage_complete:
        Map.get(
          usage,
          :billing_usage_complete,
          cache_counts_consistent?(usage, input, input_includes_cached)
        ),
      usage_reported:
        MapAccess.get(usage, :usage_reported) ||
          %{
            input: reported?(usage, [:input, :prompt_tokens, :input_tokens, :promptTokenCount]),
            output:
              reported?(usage, [
                :output,
                :completion_tokens,
                :output_tokens,
                :candidatesTokenCount
              ])
          },
      input: input,
      output: output,
      reasoning: reasoning,
      cached_input: cached_input,
      cache_creation: cache_creation,
      input_includes_cached: input_includes_cached,
      add_reasoning_to_cost: get_add_reasoning_to_cost(usage),
      tool_usage: resolve_tool_usage(usage),
      image_usage: image_usage(MapAccess.get(usage, :image_usage)),
      input_tokens: input,
      output_tokens: output,
      total_tokens: total_tokens,
      cache_read_tokens: cached_input,
      cache_write_tokens: cache_creation,
      cached_tokens: cached_input,
      cache_creation_tokens: cache_creation,
      cache_write_tokens_by_ttl: cache_write_tokens_by_ttl,
      reasoning_tokens: reasoning
    }

    usage
    |> Map.take([:cache_storage_token_hours, "cache_storage_token_hours"])
    |> Map.merge(canonical)
  end

  defp first_present(usage, keys) do
    Enum.find_value(keys, fn key -> MapAccess.get(usage, key) end)
  end

  defp reported?(usage, keys) do
    Enum.any?(keys, &(not is_nil(MapAccess.get(usage, &1))))
  end

  defp cache_counts_consistent?(usage, input, includes_cached) do
    read =
      first_present(usage, [
        :cache_read_tokens,
        :cache_read_input_tokens,
        :cached_tokens,
        :cached_input
      ]) ||
        get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in(usage, ["input_tokens_details", "cached_tokens"])

    write =
      first_present(usage, [
        :cache_write_tokens,
        :cache_creation_tokens,
        :cache_creation_input_tokens
      ]) ||
        get_in(usage, ["prompt_tokens_details", "cache_write_tokens"]) ||
        get_in(usage, ["input_tokens_details", "cache_write_tokens"])

    with {:ok, read_count} <- raw_count(read),
         {:ok, write_count} <- raw_count(write),
         true <- not includes_cached or not is_number(input) or read_count + write_count <= input do
      true
    else
      _ -> false
    end
  end

  defp raw_count(nil), do: {:ok, 0}

  defp raw_count(value) do
    case safe_to_number(value) do
      {:ok, count} when count >= 0 and (not is_float(value) or value == count) ->
        {:ok, count}

      _ ->
        :error
    end
  end

  @doc false
  @spec normalize_counter(any()) :: any()
  def normalize_counter(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> value
    end
  end

  def normalize_counter(value), do: value

  defp total_tokens_from_usage(usage, input, output) do
    total =
      first_present(usage, [:total_tokens, "total_tokens", :totalTokenCount, "totalTokenCount"])

    case normalize_counter(total) do
      value when is_number(value) -> value
      nil -> safe_total_tokens(input, output)
      _invalid -> safe_total_tokens(input, output) || total
    end
  end

  defp safe_total_tokens(input, output) when is_number(input) and is_number(output) do
    input + output
  end

  defp safe_total_tokens(_input, _output), do: nil

  defp detect_input_includes_cached(usage) do
    case Map.get(usage, :input_includes_cached, Map.get(usage, "input_includes_cached")) do
      flag when is_boolean(flag) -> flag
      _ -> detect_input_includes_cached_from_format(usage)
    end
  end

  defp detect_input_includes_cached_from_format(usage) do
    has_openai_format =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) != nil or
        get_in(usage, [:prompt_tokens_details, :cached_tokens]) != nil or
        get_in(usage, ["input_tokens_details", "cached_tokens"]) != nil or
        get_in(usage, [:input_tokens_details, :cached_tokens]) != nil

    has_anthropic_format =
      Map.has_key?(usage, "cache_read_input_tokens") or
        Map.has_key?(usage, :cache_read_input_tokens) or
        Map.has_key?(usage, "cache_creation_input_tokens") or
        Map.has_key?(usage, :cache_creation_input_tokens) or
        Map.has_key?(usage, "cacheReadInputTokens") or
        Map.has_key?(usage, :cacheReadInputTokens) or
        Map.has_key?(usage, "cacheWriteInputTokens") or
        Map.has_key?(usage, :cacheWriteInputTokens) or
        Map.has_key?(usage, "cacheReadInputTokenCount") or
        Map.has_key?(usage, :cacheReadInputTokenCount) or
        Map.has_key?(usage, "cacheWriteInputTokenCount") or
        Map.has_key?(usage, :cacheWriteInputTokenCount)

    cond do
      has_openai_format -> true
      has_anthropic_format -> false
      true -> true
    end
  end

  defp get_add_reasoning_to_cost(usage) do
    MapAccess.get(usage, :add_reasoning_to_cost) ||
      MapAccess.get(usage, "add_reasoning_to_cost") ||
      google_gemini_format?(usage)
  end

  defp resolve_tool_usage(usage) do
    existing =
      MapAccess.get(usage, :tool_usage) || MapAccess.get(usage, "tool_usage") || %{}

    normalized = Tool.normalize(existing)

    if map_size(normalized) > 0 do
      normalized
    else
      server_tool_use =
        MapAccess.get(usage, :server_tool_use) || MapAccess.get(usage, "server_tool_use") || %{}

      web_search =
        MapAccess.get(server_tool_use, :web_search_requests) ||
          MapAccess.get(server_tool_use, "web_search_requests")

      if is_number(web_search) and web_search > 0 do
        ReqLLM.Usage.Tool.build(:web_search, web_search)
      else
        sources =
          MapAccess.get(usage, :num_sources_used) ||
            MapAccess.get(usage, "num_sources_used")

        if is_number(sources) and sources > 0 do
          ReqLLM.Usage.Tool.build(:web_search, sources, :source)
        else
          %{}
        end
      end
    end
  end

  defp google_gemini_format?(usage) do
    Map.has_key?(usage, "thoughtsTokenCount") or
      Map.has_key?(usage, :thoughtsTokenCount)
  end

  defp get_reasoning_tokens(usage) do
    reasoning =
      get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
        get_in(usage, [:completion_tokens_details, :reasoning_tokens]) ||
        get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
        get_in(usage, [:output_tokens_details, :reasoning_tokens]) ||
        get_in(usage, ["output_tokens_details", "thinking_tokens"]) ||
        get_in(usage, [:output_tokens_details, :thinking_tokens]) ||
        MapAccess.get(usage, "reasoning_tokens") ||
        MapAccess.get(usage, :reasoning_tokens) ||
        MapAccess.get(usage, "reasoning_output_tokens") ||
        MapAccess.get(usage, :reasoning_output_tokens)

    case reasoning do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp get_cached_input_tokens(usage, input, input_includes_cached) do
    cached =
      MapAccess.get(usage, :cache_read_tokens) ||
        MapAccess.get(usage, "cache_read_tokens") ||
        MapAccess.get(usage, :cache_read_input_tokens) ||
        MapAccess.get(usage, "cache_read_input_tokens") ||
        MapAccess.get(usage, :cacheReadInputTokens) ||
        MapAccess.get(usage, "cacheReadInputTokens") ||
        MapAccess.get(usage, :cacheReadInputTokenCount) ||
        MapAccess.get(usage, "cacheReadInputTokenCount") ||
        MapAccess.get(usage, :cached_input) ||
        MapAccess.get(usage, "cached_input") ||
        MapAccess.get(usage, :cached_tokens) ||
        MapAccess.get(usage, "cached_tokens") ||
        get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in(usage, [:prompt_tokens_details, :cached_tokens]) ||
        get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
        get_in(usage, [:input_tokens_details, :cached_tokens])

    if input_includes_cached do
      clamp_tokens(cached, input)
    else
      safe_to_int(cached)
    end
  end

  defp get_cache_creation_tokens(usage, input, input_includes_cached) do
    creation =
      MapAccess.get(usage, :cache_write_tokens) ||
        MapAccess.get(usage, "cache_write_tokens") ||
        MapAccess.get(usage, :cache_creation_tokens) ||
        MapAccess.get(usage, :cache_creation_input_tokens) ||
        MapAccess.get(usage, "cache_creation_input_tokens") ||
        MapAccess.get(usage, :cache_creation) ||
        MapAccess.get(usage, :cacheWriteInputTokens) ||
        MapAccess.get(usage, "cacheWriteInputTokens") ||
        MapAccess.get(usage, :cacheWriteInputTokenCount) ||
        MapAccess.get(usage, "cacheWriteInputTokenCount") ||
        MapAccess.get(usage, :cache_write_input_tokens) ||
        MapAccess.get(usage, "cache_write_input_tokens") ||
        get_in(usage, ["prompt_tokens_details", "cache_write_tokens"]) ||
        get_in(usage, [:prompt_tokens_details, :cache_write_tokens]) ||
        get_in(usage, ["input_tokens_details", "cache_write_tokens"]) ||
        get_in(usage, [:input_tokens_details, :cache_write_tokens])

    creation =
      case creation do
        %{} = groups -> groups |> Map.values() |> Enum.map(&safe_to_int/1) |> Enum.sum()
        value -> value
      end

    if input_includes_cached do
      clamp_tokens(creation, input)
    else
      safe_to_int(creation)
    end
  end

  defp cache_write_groups(usage) do
    case MapAccess.get(usage, :cache_write_tokens_by_ttl) || MapAccess.get(usage, :cache_creation) do
      %{} = groups ->
        five_minutes = MapAccess.get(groups, :ephemeral_5m_input_tokens)
        one_hour = MapAccess.get(groups, :ephemeral_1h_input_tokens)

        if is_nil(five_minutes) and is_nil(one_hour) do
          if Map.has_key?(groups, "5m") or Map.has_key?(groups, "1h") or
               Map.has_key?(groups, :"5m") or Map.has_key?(groups, :"1h"),
             do: groups,
             else: nil
        else
          %{"5m" => five_minutes || 0, "1h" => one_hour || 0}
        end

      _ ->
        nil
    end
  end

  defp safe_to_int(nil), do: 0
  defp safe_to_int(n) when is_integer(n), do: max(n, 0)
  defp safe_to_int(n) when is_float(n), do: max(trunc(n), 0)

  defp safe_to_int(n) when is_binary(n) do
    case normalize_counter(n) do
      value when is_integer(value) -> max(value, 0)
      _ -> 0
    end
  end

  defp safe_to_int(_), do: 0

  defp clamp_tokens(value, max_allowed) when is_number(max_allowed) do
    case safe_to_number(value) do
      {:ok, int} ->
        int
        |> max(0)
        |> min(max(max_allowed, 0))

      _ ->
        0
    end
  end

  defp clamp_tokens(_value, _max_allowed), do: 0

  defp safe_to_number(value) when is_integer(value), do: {:ok, value}
  defp safe_to_number(value) when is_float(value), do: {:ok, trunc(value)}

  defp safe_to_number(value) when is_binary(value) do
    case normalize_counter(value) do
      number when is_integer(number) -> {:ok, number}
      _ -> :error
    end
  end

  defp safe_to_number(_), do: :error
end
