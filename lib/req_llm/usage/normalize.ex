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
    compute_units = MapAccess.get_raw(usage, :compute_units)

    input =
      first_present(usage, [
        :input,
        "input",
        :prompt_tokens,
        "prompt_tokens",
        :input_tokens,
        "input_tokens"
      ])
      |> normalize_token_counter()

    output =
      first_present(usage, [
        :output,
        "output",
        :completion_tokens,
        "completion_tokens",
        :output_tokens,
        "output_tokens"
      ])
      |> normalize_token_counter()

    reasoning =
      case first_present(usage, [:reasoning, "reasoning", :reasoning_tokens, "reasoning_tokens"]) do
        nil -> get_reasoning_tokens(usage)
        value -> normalize_counter(value)
      end

    cached_input = get_cached_input_tokens(usage, input, input_includes_cached)
    cache_creation = get_cache_creation_tokens(usage, input, input_includes_cached)
    cache_write_tokens_by_ttl = cache_write_groups(usage)
    total_tokens = total_tokens_from_usage(usage, input, output)

    canonical = %{
      billing_usage_complete:
        MapAccess.get_raw(usage, :billing_usage_complete) in [nil, true] and
          valid_token_count?(input) and valid_token_count?(output) and
          valid_token_count?(reasoning) and
          compute_units_billable?(compute_units) and
          usage_reported_valid?(MapAccess.get_raw(usage, :usage_reported)) and
          boolean_fact_valid?(MapAccess.get_raw(usage, :input_includes_cached)) and
          boolean_fact_valid?(MapAccess.get_raw(usage, :add_reasoning_to_cost)) and
          cache_write_groups_valid?(cache_write_tokens_by_ttl, usage) and
          cache_counts_consistent?(usage, input, input_includes_cached) and
          Tool.valid_usage?(MapAccess.get_raw(usage, :tool_usage)) and
          Image.valid_usage?(MapAccess.get_raw(usage, :image_usage)),
      usage_reported: normalize_usage_reported(usage),
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

    retained =
      usage
      |> Map.take([
        :cache_storage_token_hours,
        "cache_storage_token_hours",
        :input_tokens_details,
        "input_tokens_details",
        :output_tokens_details,
        "output_tokens_details"
      ])
      |> Map.merge(canonical)

    if is_nil(compute_units) do
      retained
    else
      Map.put(retained, :compute_units, normalize_counter(compute_units))
    end
  end

  defp compute_units_billable?(nil), do: true

  defp compute_units_billable?(value) do
    normalize_counter(value) === 0
  end

  defp detail_count(usage, field, key) do
    case MapAccess.get(usage, field) do
      details when is_map(details) -> Map.get(details, key, Map.get(details, Atom.to_string(key)))
      _ -> nil
    end
  end

  defp first_present(usage, keys) do
    keys
    |> Enum.map(&MapAccess.get_raw(usage, &1))
    |> Enum.find(&(not is_nil(&1)))
  end

  defp normalize_token_counter(nil), do: 0
  defp normalize_token_counter(value), do: normalize_counter(value)

  defp reported?(usage, keys) do
    Enum.any?(keys, &(not is_nil(MapAccess.get_raw(usage, &1))))
  end

  defp normalize_usage_reported(usage) do
    reported = MapAccess.get_raw(usage, :usage_reported)

    if usage_reported_valid?(reported) do
      %{
        input:
          MapAccess.get_raw(
            reported,
            :input,
            reported?(usage, [:input, :prompt_tokens, :input_tokens, :promptTokenCount])
          ),
        output:
          MapAccess.get_raw(
            reported,
            :output,
            reported?(usage, [:output, :completion_tokens, :output_tokens, :candidatesTokenCount])
          )
      }
    else
      %{input: false, output: false}
    end
  end

  defp usage_reported_valid?(nil), do: true

  defp usage_reported_valid?(reported) when is_map(reported) do
    Enum.all?([:input, :output], fn key ->
      MapAccess.get_raw(reported, key, false) in [true, false]
    end)
  end

  defp usage_reported_valid?(_reported), do: false

  defp boolean_fact_valid?(value), do: value in [nil, true, false]

  defp valid_token_count?(value), do: is_integer(value) and value >= 0

  defp cache_counts_consistent?(usage, input, includes_cached) do
    read = raw_cache_read(usage)
    write = raw_cache_write(usage)

    with {:ok, read_count} <- raw_count(read),
         {:ok, write_count} <- raw_cache_write_count(write),
         true <- not includes_cached or not is_number(input) or read_count + write_count <= input do
      true
    else
      _ -> false
    end
  end

  defp raw_cache_write_count(groups) when is_map(groups) do
    Enum.reduce_while(groups, {:ok, 0}, fn {_key, value}, {:ok, total} ->
      case raw_count(value) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp raw_cache_write_count(value), do: raw_count(value)

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
      nil -> detect_input_includes_cached_from_format(usage)
      flag -> flag
    end
  end

  defp detect_input_includes_cached_from_format(usage) do
    has_openai_format =
      detail_count(usage, :prompt_tokens_details, :cached_tokens) != nil or
        detail_count(usage, :input_tokens_details, :cached_tokens) != nil

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
    case MapAccess.get_raw(usage, :add_reasoning_to_cost) do
      nil -> google_gemini_format?(usage)
      value -> value
    end
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
      detail_count(usage, :completion_tokens_details, :reasoning_tokens) ||
        detail_count(usage, :output_tokens_details, :reasoning_tokens) ||
        detail_count(usage, :output_tokens_details, :thinking_tokens) ||
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
    cached = raw_cache_read(usage)

    if input_includes_cached do
      clamp_tokens(cached, input)
    else
      safe_to_int(cached)
    end
  end

  defp get_cache_creation_tokens(usage, input, input_includes_cached) do
    creation = raw_cache_write(usage)

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

  defp raw_cache_read(usage) do
    raw_cache_field(
      usage,
      [
        :cache_read_tokens,
        :cache_read_input_tokens,
        :cacheReadInputTokens,
        :cacheReadInputTokenCount,
        :cached_input,
        :cached_tokens
      ],
      :cached_tokens
    )
  end

  defp raw_cache_write(usage) do
    raw_cache_field(
      usage,
      [
        :cache_write_tokens,
        :cache_creation_tokens,
        :cache_creation_input_tokens,
        :cache_creation,
        :cacheWriteInputTokens,
        :cacheWriteInputTokenCount,
        :cache_write_input_tokens
      ],
      :cache_write_tokens
    )
  end

  defp raw_cache_field(usage, aliases, detail_key) do
    values = Enum.map(aliases, &MapAccess.get_raw(usage, &1))

    details =
      Enum.map([:prompt_tokens_details, :input_tokens_details], fn field ->
        usage |> MapAccess.get_raw(field) |> MapAccess.get_raw(detail_key)
      end)

    Enum.find(values ++ details, &(not is_nil(&1)))
  end

  defp cache_write_groups(usage) do
    case MapAccess.get_raw(usage, :cache_write_tokens_by_ttl) do
      nil ->
        case MapAccess.get_raw(usage, :cache_creation) do
          groups when is_map(groups) -> normalize_cache_write_groups(groups)
          _ -> nil
        end

      groups when is_map(groups) ->
        normalize_cache_write_groups(groups)

      invalid ->
        invalid
    end
  end

  defp normalize_cache_write_groups(groups) do
    Map.new(groups, fn {ttl, count} ->
      {cache_ttl_key(ttl), normalize_counter(count)}
    end)
  end

  defp cache_ttl_key(key) when key in [:ephemeral_5m_input_tokens, "ephemeral_5m_input_tokens"],
    do: "5m"

  defp cache_ttl_key(key) when key in [:ephemeral_1h_input_tokens, "ephemeral_1h_input_tokens"],
    do: "1h"

  defp cache_ttl_key(key) when is_atom(key), do: Atom.to_string(key)
  defp cache_ttl_key(key), do: key

  defp cache_write_groups_valid?(nil, _usage), do: true

  defp cache_write_groups_valid?(groups, usage) when is_map(groups) do
    source =
      MapAccess.get_raw(usage, :cache_write_tokens_by_ttl) ||
        MapAccess.get_raw(usage, :cache_creation)

    map_size(groups) == map_size(source) and
      Enum.all?(groups, fn {ttl, count} ->
        is_binary(ttl) and is_integer(count) and count >= 0
      end)
  end

  defp cache_write_groups_valid?(_, _usage), do: false

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
