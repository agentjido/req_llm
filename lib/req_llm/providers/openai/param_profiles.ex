defmodule ReqLLM.Providers.OpenAI.ParamProfiles do
  @moduledoc """
  Defines reusable parameter transformation profiles for OpenAI models.

  Profiles are composable sets of transformation rules that can be applied to model parameters.
  Rules are resolved from model metadata first, then inferred from capabilities.
  """

  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  @type profile_name :: atom

  @profiles %{
    reasoning: [
      {:rename, :max_tokens, :max_completion_tokens,
       "Renamed :max_tokens to :max_completion_tokens for reasoning models"}
    ],
    no_temperature: [
      {:drop, :temperature, "This model does not support :temperature – dropped"}
    ],
    temperature_fixed_1: [
      {:drop, :temperature, "This model only supports temperature=1 (default) – dropped"}
    ],
    no_sampling_params: [
      {:drop, :temperature, "This model does not support sampling parameters – dropped"},
      {:drop, :top_p, "This model does not support sampling parameters – dropped"},
      {:drop, :top_k, "This model does not support sampling parameters – dropped"}
    ]
  }

  @doc """
  Returns the composed transformation steps (profiles) for a given operation and model.

  Steps are resolved from model metadata first, then inferred from capabilities when missing.

  ## Examples

      iex> {:ok, model} = ReqLLM.model("openai:o3-mini")
      iex> steps = ReqLLM.Providers.OpenAI.ParamProfiles.steps_for(:chat, model)
      iex> length(steps) > 0
      true
  """
  def steps_for(operation, %LLMDB.Model{} = model) do
    profiles = profiles_for(operation, model)

    canonical_steps = [
      {:transform, :reasoning_effort, &translate_reasoning_effort/1, nil},
      {:drop, :reasoning_token_budget, nil}
    ]

    canonical_steps ++ Enum.flat_map(profiles, &Map.get(@profiles, &1, []))
  end

  defp translate_reasoning_effort(:low), do: "low"
  defp translate_reasoning_effort(:medium), do: "medium"
  defp translate_reasoning_effort(:high), do: "high"
  defp translate_reasoning_effort(:default), do: nil
  defp translate_reasoning_effort(other), do: other

  defp profiles_for(:chat, %LLMDB.Model{} = model) do
    []
    |> add_if(reasoning_model?(model), :reasoning)
    |> add_if(no_sampling_params?(model), :no_sampling_params)
    |> add_if(temperature_unsupported?(model), :no_temperature)
    |> add_if(temperature_fixed_one?(model), :temperature_fixed_1)
    |> Enum.uniq()
  end

  defp profiles_for(_op, _model), do: []

  defp reasoning_model?(%LLMDB.Model{capabilities: caps, id: model_name}) when is_map(caps) do
    has_reasoning_capability?(caps) || AdapterHelpers.reasoning_model?(model_name)
  end

  defp reasoning_model?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.reasoning_model?(model_name)
  end

  defp has_reasoning_capability?(caps) do
    case caps[:reasoning] || caps["reasoning"] do
      true -> true
      %{enabled: true} -> true
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  defp no_sampling_params?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.gpt5_model?(model_name) || AdapterHelpers.o_series_model?(model_name)
  end

  defp temperature_unsupported?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.o_series_model?(model_name)
  end

  defp temperature_fixed_one?(%LLMDB.Model{id: _model_name}), do: false

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list
end
