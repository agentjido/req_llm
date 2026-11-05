defmodule ReqLLM.Usage.ProviderCost do
  @moduledoc """
  Normalizes the charge that a provider reports for a request.

  Only `cost` is required. OpenRouter can also report whether the request used
  BYOK and what the upstream provider charged. Missing or invalid optional values
  are not estimated.
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
    validate(MapAccess.get_raw(usage, :provider_cost)) || from_raw_usage(usage)
  end

  def from_usage(_usage), do: nil

  @doc false
  @spec validate(map()) :: t() | nil
  def validate(stored) when is_map(stored) do
    build(
      MapAccess.get_raw(stored, :cost),
      MapAccess.get_raw(stored, :byok),
      MapAccess.get_raw(stored, :upstream_cost)
    )
  end

  def validate(_stored), do: nil

  defp from_raw_usage(usage) do
    build(
      MapAccess.get_raw(usage, :cost),
      MapAccess.get_raw(usage, :is_byok),
      upstream_cost(MapAccess.get_raw(usage, :cost_details))
    )
  end

  defp build(cost, byok, upstream_cost) when is_number(cost) and cost >= 0 do
    %{cost: cost, byok: byok == true, upstream_cost: valid_amount(upstream_cost)}
  end

  defp build(_cost, _byok, _upstream_cost), do: nil

  defp upstream_cost(details) when is_map(details) do
    valid_amount(MapAccess.get_raw(details, :upstream_inference_cost)) ||
      upstream_parts(
        details,
        :upstream_inference_prompt_cost,
        :upstream_inference_completions_cost
      ) ||
      upstream_parts(details, :upstream_inference_input_cost, :upstream_inference_output_cost)
  end

  defp upstream_cost(_details), do: nil

  defp upstream_parts(details, input_key, output_key) do
    with input when is_number(input) <- MapAccess.get_raw(details, input_key),
         output when is_number(output) <- MapAccess.get_raw(details, output_key),
         true <- input >= 0 and output >= 0 do
      input + output
    else
      _invalid -> nil
    end
  end

  defp valid_amount(value) when is_number(value) and value >= 0, do: value
  defp valid_amount(_value), do: nil
end
