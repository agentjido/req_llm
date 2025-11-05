defmodule ReqLLM.Providers.OpenAI.ParamProfiles do
  @moduledoc """
  Defines reusable parameter transformation profiles for OpenAI models.

  Profiles are composable sets of transformation rules that can be applied to model parameters.
  Rules are resolved from model metadata first, then inferred from capabilities.
  """

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

      iex> model = ReqLLM.Model.from!("openai:o3-mini")
      iex> steps = ReqLLM.Providers.OpenAI.ParamProfiles.steps_for(:chat, model)
      iex> length(steps) > 0
      true
  """
  def steps_for(operation, %ReqLLM.Model{} = model) do
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

  defp profiles_for(:chat, %ReqLLM.Model{} = model) do
    []
    |> add_if(reasoning_model?(model), :reasoning)
    |> add_if(no_sampling_params?(model), :no_sampling_params)
    |> add_if(temperature_unsupported?(model), :no_temperature)
    |> add_if(temperature_fixed_one?(model), :temperature_fixed_1)
    |> Enum.uniq()
  end

  defp profiles_for(_op, _model), do: []

  defp reasoning_model?(%ReqLLM.Model{capabilities: caps, model: model_name}) when is_map(caps) do
    Map.get(caps, :reasoning) == true || Map.get(caps, "reasoning") == true ||
      o_series_model?(model_name) || gpt5_model?(model_name) ||
      reasoning_codex_model?(model_name)
  end

  defp reasoning_model?(%ReqLLM.Model{model: model_name}) do
    o_series_model?(model_name) || gpt5_model?(model_name) ||
      reasoning_codex_model?(model_name)
  end

  defp no_sampling_params?(%ReqLLM.Model{model: model_name}), do: gpt5_model?(model_name)

  defp temperature_unsupported?(%ReqLLM.Model{model: model_name}) do
    o_series_model?(model_name)
  end

  defp temperature_fixed_one?(%ReqLLM.Model{model: _model_name}), do: false

  defp o_series_model?(<<"o1", _::binary>>), do: true
  defp o_series_model?(<<"o3", _::binary>>), do: true
  defp o_series_model?(<<"o4", _::binary>>), do: true
  defp o_series_model?(_), do: false

  defp gpt5_model?("gpt-5-chat-latest"), do: false
  defp gpt5_model?(<<"gpt-5", _::binary>>), do: true
  defp gpt5_model?(_), do: false

  defp reasoning_codex_model?(<<"codex", rest::binary>>),
    do: String.contains?(rest, "mini-latest")

  defp reasoning_codex_model?(_), do: false

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list
end
