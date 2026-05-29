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
    max_completion_tokens: [
      {:rename, :max_tokens, :max_completion_tokens,
       "Renamed :max_tokens to :max_completion_tokens for this model"}
    ],
    no_temperature: [
      {:drop, :temperature, "This model does not support :temperature – dropped"}
    ],
    temperature_fixed_1: [
      {:drop, :temperature, "This model only supports temperature=1 (default) – dropped"}
    ],
    audio_output_chat: [
      {:set_default, :modalities, ["text", "audio"], nil},
      {:set_default, :audio, %{voice: "alloy", format: "mp3"}, nil}
    ],
    no_sampling_params: [
      {:drop, :temperature, "This model does not support sampling parameters – dropped"},
      {:drop, :top_p, "This model does not support sampling parameters – dropped"},
      {:drop, :top_k, "This model does not support sampling parameters – dropped"}
    ],
    gpt5_pro_reasoning: [
      {:set_default, :reasoning_effort, "high", "Set :reasoning_effort to high for GPT-5 Pro"},
      {:enforce_constant, :reasoning_effort, "high", :fix,
       "GPT-5 Pro only supports :reasoning_effort high – using high"}
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

  defp translate_reasoning_effort(:none), do: "none"
  defp translate_reasoning_effort(:minimal), do: "minimal"
  defp translate_reasoning_effort(:low), do: "low"
  defp translate_reasoning_effort(:medium), do: "medium"
  defp translate_reasoning_effort(:high), do: "high"
  defp translate_reasoning_effort(:xhigh), do: "xhigh"
  defp translate_reasoning_effort(:default), do: nil
  defp translate_reasoning_effort(other), do: other

  defp profiles_for(:chat, %LLMDB.Model{} = model) do
    []
    |> add_if(reasoning_model?(model), :reasoning)
    |> add_if(max_completion_tokens_required?(model), :max_completion_tokens)
    |> add_if(no_sampling_params?(model), :no_sampling_params)
    |> add_if(temperature_unsupported?(model), :no_temperature)
    |> add_if(temperature_fixed_one?(model), :temperature_fixed_1)
    |> add_if(chat_latest_model?(model), :temperature_fixed_1)
    |> add_if(audio_output_chat_model?(model), :audio_output_chat)
    |> add_if(gpt5_pro_model?(model), :gpt5_pro_reasoning)
    |> Enum.uniq()
  end

  defp profiles_for(_op, _model), do: []

  defp reasoning_model?(%LLMDB.Model{capabilities: caps, id: model_name}) when is_map(caps) do
    has_reasoning_capability?(caps) || AdapterHelpers.reasoning_model?(model_name)
  end

  defp reasoning_model?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.reasoning_model?(model_name)
  end

  defp max_completion_tokens_required?(%LLMDB.Model{id: "chat-latest"}), do: true
  defp max_completion_tokens_required?(%LLMDB.Model{}), do: false
  defp chat_latest_model?(%LLMDB.Model{id: "chat-latest"}), do: true
  defp chat_latest_model?(%LLMDB.Model{}), do: false
  defp audio_output_chat_model?(%LLMDB.Model{id: "gpt-audio" <> _}), do: true
  defp audio_output_chat_model?(%LLMDB.Model{}), do: false

  defp has_reasoning_capability?(caps) do
    case caps[:reasoning] do
      true -> true
      %{enabled: true} -> true
      _ -> false
    end
  end

  defp no_sampling_params?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.gpt5_model?(model_name) || AdapterHelpers.o_series_model?(model_name)
  end

  defp gpt5_pro_model?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.gpt5_pro_model?(model_name)
  end

  defp temperature_unsupported?(%LLMDB.Model{id: model_name}) do
    AdapterHelpers.o_series_model?(model_name)
  end

  defp temperature_fixed_one?(%LLMDB.Model{id: _model_name}), do: false

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list
end
