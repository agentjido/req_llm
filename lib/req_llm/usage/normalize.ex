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
      first_present(usage, [
        :input,
        "input",
        :prompt_tokens,
        "prompt_tokens",
        :input_tokens,
        "input_tokens"
      ]) || 0

    output =
      first_present(usage, [
        :output,
        "output",
        :completion_tokens,
        "completion_tokens",
        :output_tokens,
        "output_tokens"
      ]) || 0

    reasoning =
      first_present(usage, [:reasoning, "reasoning", :reasoning_tokens, "reasoning_tokens"]) ||
        get_reasoning_tokens(usage)

    cached_input = get_cached_input_tokens(usage, input, input_includes_cached)
    cache_creation = get_cache_creation_tokens(usage, input, input_includes_cached)
    total_tokens = total_tokens_from_usage(usage, input, output)

    %{
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
      cached_tokens: cached_input,
      cache_creation_tokens: cache_creation,
      reasoning_tokens: reasoning
    }
  end

  defp first_present(usage, keys) do
    Enum.find_value(keys, fn key -> MapAccess.get(usage, key) end)
  end

  defp total_tokens_from_usage(usage, input, output) do
    total =
      first_present(usage, [:total_tokens, "total_tokens", :totalTokenCount, "totalTokenCount"])

    case total do
      value when is_number(value) -> value
      _ -> safe_total_tokens(input, output)
    end
  end

  defp safe_total_tokens(input, output) when is_number(input) and is_number(output) do
    input + output
  end

  defp safe_total_tokens(_input, _output), do: nil

  defp detect_input_includes_cached(usage) do
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
      is_google_gemini_format(usage)
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

  defp is_google_gemini_format(usage) do
    Map.has_key?(usage, "thoughtsTokenCount") or
      Map.has_key?(usage, :thoughtsTokenCount)
  end

  defp get_reasoning_tokens(usage) do
    reasoning =
      get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
        get_in(usage, [:completion_tokens_details, :reasoning_tokens]) ||
        get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
        get_in(usage, [:output_tokens_details, :reasoning_tokens]) ||
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
      MapAccess.get(usage, :cache_creation_input_tokens) ||
        MapAccess.get(usage, "cache_creation_input_tokens") ||
        MapAccess.get(usage, :cacheWriteInputTokens) ||
        MapAccess.get(usage, "cacheWriteInputTokens") ||
        MapAccess.get(usage, :cacheWriteInputTokenCount) ||
        MapAccess.get(usage, "cacheWriteInputTokenCount") ||
        MapAccess.get(usage, :cache_write_input_tokens) ||
        MapAccess.get(usage, "cache_write_input_tokens")

    if input_includes_cached do
      clamp_tokens(creation, input)
    else
      safe_to_int(creation)
    end
  end

  defp safe_to_int(nil), do: 0
  defp safe_to_int(n) when is_integer(n), do: max(n, 0)
  defp safe_to_int(n) when is_float(n), do: max(trunc(n), 0)
  defp safe_to_int(_), do: 0

  defp clamp_tokens(value, max_allowed) do
    case safe_to_number(value) do
      {:ok, int} ->
        int
        |> max(0)
        |> min(max(max_allowed, 0))

      _ ->
        0
    end
  end

  defp safe_to_number(value) when is_integer(value), do: {:ok, value}
  defp safe_to_number(value) when is_float(value), do: {:ok, trunc(value)}
  defp safe_to_number(_), do: :error
end
