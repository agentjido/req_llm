defmodule ReqLLM.Usage do
  @moduledoc """
  Usage normalization helpers.

  Provides a stable entrypoint for normalizing provider usage maps to ReqLLM's
  canonical usage shape.
  """

  alias ReqLLM.MapAccess
  alias ReqLLM.Usage.Normalize

  @counter_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input,
    :output,
    :cache_read_tokens,
    :cache_write_tokens,
    :cached_tokens,
    :reasoning_tokens,
    :cache_creation_tokens,
    :reasoning,
    :cached_input,
    :cache_creation
  ]

  @zero_usage %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    input: 0,
    output: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    cached_tokens: 0,
    reasoning_tokens: 0,
    cache_creation_tokens: 0
  }

  @doc """
  Normalize usage into a canonical map.

  Guarantees canonical token keys:
  - `:input_tokens`
  - `:output_tokens`
  - `:total_tokens`

  Also guarantees compatibility aliases:
  - `:input`
  - `:output`
  - `:cached_tokens` for `:cache_read_tokens`
  - `:cache_creation_tokens` for `:cache_write_tokens`

  Prompt cache reads and writes are available as separate counters:
  - `:cache_read_tokens`
  - `:cache_write_tokens`

  Canonical counters accept numbers and base-10 integer strings. Malformed
  component counters remain visible instead of becoming zero. A malformed
  explicit total is replaced only when valid input and output counters can
  produce a derived total.
  """
  @spec normalize(map() | any()) :: map()
  def normalize(usage) when is_map(usage) do
    normalized = Normalize.normalize(usage)

    input_tokens = MapAccess.get(normalized, :input_tokens) || MapAccess.get(normalized, :input)

    output_tokens =
      MapAccess.get(normalized, :output_tokens) || MapAccess.get(normalized, :output)

    total_tokens =
      case MapAccess.get(normalized, :total_tokens) do
        nil -> derive_total_tokens(input_tokens, output_tokens)
        value -> value
      end

    normalized
    |> Map.put(:input_tokens, input_tokens)
    |> Map.put(:output_tokens, output_tokens)
    |> Map.put(:total_tokens, total_tokens)
    |> Map.put(:input, input_tokens)
    |> Map.put(:output, output_tokens)
  end

  def normalize(_) do
    Map.take(@zero_usage, [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :input,
      :output,
      :cache_read_tokens,
      :cache_write_tokens,
      :cached_tokens,
      :cache_creation_tokens
    ])
  end

  @doc """
  Zero out a usage map for application-layer cache hits.

  Existing keys are preserved where possible, but numeric values are reset so
  callers can reliably distinguish response-cache hits from provider-native
  cache reads that still incur an API call.
  """
  @spec zero(map() | any()) :: map()
  def zero(usage) when is_map(usage) do
    Map.merge(@zero_usage, zero_usage_map(usage))
  end

  def zero(_), do: @zero_usage

  @doc """
  Merge two usage maps and take the maximum numeric value for each field.

  Canonical token counters can be numbers or base-10 integer strings. Valid
  integer strings are normalized before cumulative values are compared.
  Malformed counters remain visible when no valid value exists, but they do
  not replace an earlier valid counter and are not used to recompute totals.
  Missing input or output counters keep the existing zero default.
  """
  @spec merge(map(), map()) :: map()
  def merge(existing, incoming) when is_map(existing) and is_map(incoming) do
    existing
    |> normalize_counter_values()
    |> Map.merge(normalize_counter_values(incoming), &merge_value/3)
    |> recompute_totals()
  end

  defp recompute_totals(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    usage =
      if is_number(input) and is_number(output) do
        Map.put(usage, :total_tokens, input + output)
      else
        usage
      end

    usage
    |> Map.put(:input, input)
    |> Map.put(:output, output)
  end

  defp normalize_counter_values(usage) do
    Map.new(usage, fn
      {key, value} when key in @counter_keys -> {key, Normalize.normalize_counter(value)}
      entry -> entry
    end)
  end

  defp merge_value(key, existing, incoming) when key in @counter_keys do
    cond do
      is_number(existing) and is_number(incoming) -> max(existing, incoming)
      is_number(existing) -> existing
      is_number(incoming) -> incoming
      is_nil(incoming) -> existing
      true -> incoming
    end
  end

  defp merge_value(_key, existing, incoming) do
    if is_number(existing) and is_number(incoming), do: max(existing, incoming), else: incoming
  end

  defp derive_total_tokens(input_tokens, output_tokens)
       when is_number(input_tokens) and is_number(output_tokens),
       do: input_tokens + output_tokens

  defp derive_total_tokens(_, _), do: nil

  defp zero_usage_map(usage) do
    Map.new(usage, fn {key, value} -> {key, zero_usage_value(value)} end)
  end

  defp zero_usage_value(value) when is_number(value), do: 0
  defp zero_usage_value(value) when is_map(value), do: zero_usage_map(value)
  defp zero_usage_value(value) when is_list(value), do: Enum.map(value, &zero_usage_value/1)
  defp zero_usage_value(value), do: value
end
