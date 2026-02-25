defmodule ReqLLM.Usage do
  @moduledoc """
  Public usage normalization helpers.

  Provides a stable entrypoint for normalizing provider usage maps to ReqLLM's
  canonical usage shape.
  """

  alias ReqLLM.MapAccess
  alias ReqLLM.Usage.Normalize

  @doc """
  Normalize usage into a canonical map.

  Guarantees canonical token keys:
  - `:input_tokens`
  - `:output_tokens`
  - `:total_tokens`

  Also guarantees compatibility aliases:
  - `:input`
  - `:output`
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
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      input: 0,
      output: 0
    }
  end

  @doc """
  Merge two usage maps, taking the max of numeric fields (to handle
  cumulative streaming usage) and recomputing derived totals.
  """
  @spec merge(map(), map()) :: map()
  def merge(existing, incoming) when is_map(existing) and is_map(incoming) do
    existing
    |> Map.merge(incoming, fn _key, v1, v2 ->
      if is_number(v1) and is_number(v2), do: max(v1, v2), else: v2
    end)
    |> recompute_totals()
  end

  defp recompute_totals(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    usage
    |> Map.put(:total_tokens, input + output)
    |> Map.put(:input, input)
    |> Map.put(:output, output)
  end

  defp derive_total_tokens(input_tokens, output_tokens)
       when is_number(input_tokens) and is_number(output_tokens),
       do: input_tokens + output_tokens

  defp derive_total_tokens(_, _), do: nil
end
