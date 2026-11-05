defmodule ReqLLM.Usage.ProviderCost do
  @moduledoc """
  What a provider reports it charged, kept apart from the catalog estimate.

  OpenRouter includes this with every response, streaming or not: `cost` is what
  the account was charged, `is_byok` whether the caller's own upstream key served
  the request, and `cost_details` what the upstream provider charged. The
  `cost_details` keys follow the API that answered: `upstream_inference_prompt_cost`
  and `upstream_inference_completions_cost` on Chat Completions,
  `upstream_inference_input_cost` and `upstream_inference_output_cost` on the
  Responses API.

  Only `cost` is required. A request whose response omits `is_byok` counts as one
  the account paid for, and an upstream share that is absent or not a number is
  left out rather than guessed.
  """

  alias ReqLLM.MapAccess

  @type t :: %{
          cost: number(),
          byok: boolean(),
          upstream_cost: number() | nil
        }

  @doc false
  @spec from_usage(map()) :: t() | nil
  def from_usage(usage) when is_map(usage) do
    case MapAccess.get_raw(usage, :provider_cost) do
      %{} = stored -> validate(stored) || from_raw_usage(usage)
      _raw -> from_raw_usage(usage)
    end
  end

  def from_usage(_usage), do: nil

  @doc false
  @spec validate(map()) :: t() | nil
  def validate(stored) when is_map(stored) do
    with cost when is_number(cost) <- MapAccess.get_raw(stored, :cost),
         true <- valid_cost?(cost) do
      %{
        cost: cost,
        byok: MapAccess.get_raw(stored, :byok) == true,
        upstream_cost: stored_upstream_cost(stored)
      }
    else
      _ -> nil
    end
  end

  def validate(_stored), do: nil

  defp stored_upstream_cost(stored) do
    case MapAccess.get_raw(stored, :upstream_cost) do
      nil -> nil
      upstream when is_number(upstream) -> if valid_cost?(upstream), do: upstream
      _invalid -> nil
    end
  end

  defp from_raw_usage(usage) do
    with cost when is_number(cost) <- MapAccess.get_raw(usage, :cost),
         true <- valid_cost?(cost) do
      %{
        cost: cost,
        byok: MapAccess.get_raw(usage, :is_byok) == true,
        upstream_cost: upstream_cost(MapAccess.get_raw(usage, :cost_details))
      }
    else
      _ -> nil
    end
  end

  defp upstream_cost(details) when is_map(details) do
    case upstream_total(details) do
      nil -> upstream_parts(details)
      cost -> cost
    end
  end

  defp upstream_cost(_details), do: nil

  defp upstream_total(details) do
    case MapAccess.get_raw(details, :upstream_inference_cost) do
      cost when is_number(cost) -> if valid_cost?(cost), do: cost
      _other -> nil
    end
  end

  defp upstream_parts(details) do
    case {MapAccess.get_raw(details, :upstream_inference_prompt_cost),
          MapAccess.get_raw(details, :upstream_inference_completions_cost),
          MapAccess.get_raw(details, :upstream_inference_input_cost),
          MapAccess.get_raw(details, :upstream_inference_output_cost)} do
      {prompt, completions, _input, _output}
      when is_number(prompt) and is_number(completions) ->
        if valid_cost?(prompt) and valid_cost?(completions), do: prompt + completions

      {_prompt, _completions, input, output} when is_number(input) and is_number(output) ->
        if valid_cost?(input) and valid_cost?(output), do: input + output

      _other ->
        nil
    end
  end

  defp valid_cost?(value), do: value >= 0
end
