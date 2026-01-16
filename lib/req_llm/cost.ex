defmodule ReqLLM.Cost do
  @moduledoc """
  Shared cost calculation logic for token usage.

  This module provides consistent cost calculation across streaming and
  non-streaming responses, with support for:

  - Cache read/write pricing (prompt caching)
  - Reasoning/thinking token costs (Google Gemini only)

  ## Reasoning Token Handling

  Google Gemini reports thinking tokens separately from output tokens
  (`candidatesTokenCount` excludes `thoughtsTokenCount`). For this provider,
  reasoning tokens are explicitly added to output cost.

  All other providers maintain status quo behavior — reasoning tokens are
  tracked but not added to output cost (to avoid double-counting for providers
  like OpenAI where `completion_tokens` already includes reasoning).
  """

  @doc """
  Calculates cost breakdown from normalized usage data and model cost rates.

  ## Parameters

  - `usage` - Map with token counts:
    - `:input` - Input/prompt tokens
    - `:output` - Output/completion tokens
    - `:cached_input` - Cached input tokens (optional)
    - `:cache_creation` - Cache creation tokens (optional)
    - `:reasoning` - Reasoning/thinking tokens (optional)
    - `:add_reasoning_to_cost` - Boolean, true to add reasoning to output cost (optional, default: false)
  - `cost_map` - Map with cost rates (`:input`, `:output`, `:cache_read`, `:cache_write`)

  ## Returns

  - `{:ok, breakdown}` with `:input_cost`, `:output_cost`, `:total_cost` keys
  - `{:ok, nil}` if cost cannot be calculated

  ## Examples

      iex> usage = %{input: 1000, output: 500, cached_input: 200, cache_creation: 100}
      iex> cost_map = %{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75}
      iex> ReqLLM.Cost.calculate(usage, cost_map)
      {:ok, %{input_cost: ..., output_cost: ..., total_cost: ...}}
  """
  @spec calculate(map(), map() | nil) ::
          {:ok, %{input_cost: float(), output_cost: float(), total_cost: float()} | nil}
  def calculate(_usage, nil), do: {:ok, nil}

  def calculate(%{input: input_tokens, output: output_tokens} = usage, cost_map)
      when is_map(cost_map) do
    input_rate = cost_map[:input] || cost_map["input"]
    output_rate = cost_map[:output] || cost_map["output"]

    # Cache read rate (tokens read from cache - typically cheaper)
    cache_read_rate =
      cost_map[:cached_input] || cost_map["cached_input"] ||
        cost_map[:cache_read] || cost_map["cache_read"] ||
        input_rate

    # Cache write rate (tokens written to cache - typically 1.25x input rate)
    cache_write_rate =
      cost_map[:cache_write] || cost_map["cache_write"] ||
        input_rate

    with {:ok, input_num} <- safe_to_number(input_tokens),
         {:ok, output_num} <- safe_to_number(output_tokens),
         true <- input_rate != nil and output_rate != nil do
      raw_cache_read = safe_add(Map.get(usage, :cached_input, 0))
      raw_cache_write = safe_add(Map.get(usage, :cache_creation, 0))
      total_cache = raw_cache_read + raw_cache_write

      input_includes_cached = Map.get(usage, :input_includes_cached, true)

      total_input =
        if input_includes_cached do
          input_num
        else
          input_num + total_cache
        end

      cache_read_tokens = clamp_tokens(raw_cache_read, total_input)
      cache_write_tokens = clamp_tokens(raw_cache_write, total_input)

      regular_tokens =
        if input_includes_cached do
          max(input_num - cache_read_tokens - cache_write_tokens, 0)
        else
          max(input_num, 0)
        end

      # Calculate costs (rates are per million tokens)
      input_cost =
        Float.round(
          regular_tokens / 1_000_000 * input_rate +
            cache_read_tokens / 1_000_000 * cache_read_rate +
            cache_write_tokens / 1_000_000 * cache_write_rate,
          6
        )

      # Reasoning/thinking tokens: only add for Google Gemini where they're
      # explicitly separate from output (candidatesTokenCount excludes thoughtsTokenCount).
      # All other providers: status quo (reasoning not added to avoid breaking changes).
      reasoning_tokens =
        if Map.get(usage, :add_reasoning_to_cost, false) do
          safe_int(Map.get(usage, :reasoning, 0))
        else
          0
        end

      output_cost = Float.round((output_num + reasoning_tokens) / 1_000_000 * output_rate, 6)
      total_cost = Float.round(input_cost + output_cost, 6)

      {:ok,
       %{
         input_cost: input_cost,
         output_cost: output_cost,
         total_cost: total_cost
       }}
    else
      _ -> {:ok, nil}
    end
  end

  def calculate(_usage, _cost_map), do: {:ok, nil}

  @doc """
  Adds cost breakdown fields to a usage map if model cost data is available.

  This is a convenience function for streaming that mutates the usage map directly.
  """
  @spec add_cost_to_usage(map(), map() | nil) :: map()
  def add_cost_to_usage(usage, nil), do: usage

  def add_cost_to_usage(usage, cost_map) when is_map(cost_map) do
    case calculate(usage, cost_map) do
      {:ok, %{input_cost: input_cost, output_cost: output_cost, total_cost: total_cost}} ->
        usage
        |> Map.put(:input_cost, input_cost)
        |> Map.put(:output_cost, output_cost)
        |> Map.put(:total_cost, total_cost)

      {:ok, nil} ->
        usage
    end
  end

  def add_cost_to_usage(usage, _), do: usage

  # Safely clamps a value to a valid token count within bounds.
  @spec clamp_tokens(any(), number()) :: integer()
  defp clamp_tokens(value, max_allowed) do
    case safe_to_number(value) do
      {:ok, num} ->
        num
        |> max(0)
        |> min(max(max_allowed, 0))

      _ ->
        0
    end
  end

  @spec safe_to_number(any()) :: {:ok, number()} | :error
  defp safe_to_number(value) when is_integer(value), do: {:ok, value}
  defp safe_to_number(value) when is_float(value), do: {:ok, trunc(value)}
  defp safe_to_number(_), do: :error

  # Safely converts a value to a non-negative integer.
  # Uses safe_to_number/1 internally to avoid duplication.
  @spec safe_int(any()) :: non_neg_integer()
  defp safe_int(value) do
    case safe_to_number(value) do
      {:ok, n} -> max(n, 0)
      :error -> 0
    end
  end

  defp safe_add(nil), do: 0
  defp safe_add(n) when is_number(n), do: n
  defp safe_add(_), do: 0
end
