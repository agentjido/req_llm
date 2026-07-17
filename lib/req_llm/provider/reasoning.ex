defmodule ReqLLM.Provider.Reasoning do
  @moduledoc false

  @type advisory :: %{
          required(:kind) => :ignored | :clamped | :unsupported | :lossy,
          required(:option) => atom(),
          required(:message) => String.t()
        }

  @effort_strings %{
    "none" => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh,
    "default" => :default
  }

  @budget_ignored_providers %{
    openai: "OpenAI",
    openrouter: "OpenRouter",
    groq: "Groq",
    xai: "xAI"
  }

  @spec normalize_options(keyword()) :: keyword()
  def normalize_options(opts) do
    opts
    |> normalize_thinking_flag()
    |> normalize_reasoning_alias()
  end

  @spec normalize_effort_option(keyword()) :: keyword()
  def normalize_effort_option(opts) do
    case Keyword.fetch(opts, :reasoning_effort) do
      {:ok, value} -> Keyword.put(opts, :reasoning_effort, normalize_effort(value))
      :error -> opts
    end
  end

  @spec normalize_effort(term()) :: term()
  def normalize_effort(value) when is_binary(value), do: Map.get(@effort_strings, value, value)
  def normalize_effort(value), do: value

  @spec advisories(module(), LLMDB.Model.t(), keyword(), keyword()) :: [advisory()]
  def advisories(provider_module, model, canonical_opts, translated_opts) do
    provider = provider_id(provider_module, model)

    [
      ignored_budget_advisory(provider, canonical_opts, translated_opts),
      google_effort_advisory(provider, canonical_opts, translated_opts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec messages([advisory()]) :: [String.t()]
  def messages(advisories), do: Enum.map(advisories, & &1.message)

  defp normalize_thinking_flag(opts) do
    case Keyword.pop(opts, :thinking) do
      {nil, rest} -> rest
      {false, rest} -> rest
      {true, rest} -> rest
      {thinking, rest} when is_map(thinking) -> Keyword.put(rest, :thinking, thinking)
    end
  end

  defp normalize_reasoning_alias(opts) do
    case Keyword.pop(opts, :reasoning) do
      {nil, rest} ->
        rest

      {false, rest} ->
        rest

      {true, rest} ->
        Keyword.put_new(rest, :reasoning_effort, :medium)

      {"auto", rest} ->
        rest

      {value, rest} when is_map_key(@effort_strings, value) ->
        Keyword.put_new(rest, :reasoning_effort, Map.fetch!(@effort_strings, value))
    end
  end

  defp provider_id(provider_module, model) do
    if function_exported?(provider_module, :provider_id, 0) do
      provider_module.provider_id()
    else
      model.provider
    end
  end

  defp ignored_budget_advisory(provider, canonical_opts, translated_opts) do
    case Keyword.fetch(canonical_opts, :reasoning_token_budget) do
      {:ok, budget} ->
        if !budget_consumed?(provider, budget, translated_opts), do: ignored_budget(provider)

      :error ->
        nil
    end
  end

  defp ignored_budget(provider) when is_map_key(@budget_ignored_providers, provider) do
    provider_name = Map.fetch!(@budget_ignored_providers, provider)

    %{
      kind: :ignored,
      option: :reasoning_token_budget,
      message:
        ":reasoning_token_budget is not supported by #{provider_name} effort controls and was ignored"
    }
  end

  defp ignored_budget(:anthropic) do
    %{
      kind: :ignored,
      option: :reasoning_token_budget,
      message:
        ":reasoning_token_budget was ignored because the Anthropic request did not enable budget-based thinking"
    }
  end

  defp ignored_budget(_provider), do: nil

  defp budget_consumed?(provider, _budget, _translated_opts)
       when provider in [:openai, :openrouter, :groq, :xai],
       do: false

  defp budget_consumed?(:anthropic, budget, translated_opts) do
    case Keyword.get(translated_opts, :thinking) do
      %{budget_tokens: ^budget} -> true
      %{"budget_tokens" => ^budget} -> true
      _ -> false
    end
  end

  defp budget_consumed?(_provider, _budget, _translated_opts), do: true

  defp google_effort_advisory(provider, canonical_opts, translated_opts)
       when provider in [:google, :google_vertex] do
    effort = canonical_opts |> Keyword.get(:reasoning_effort) |> normalize_effort()
    level = Keyword.get(translated_opts, :google_thinking_level)

    case {effort, level} do
      {:xhigh, level} when level in [:high, "high"] ->
        %{
          kind: :clamped,
          option: :reasoning_effort,
          message: ":reasoning_effort :xhigh was clamped to Gemini thinking level :high"
        }

      {:none, level} when level in [:minimal, "minimal"] ->
        %{
          kind: :lossy,
          option: :reasoning_effort,
          message:
            ":reasoning_effort :none has no exact Gemini thinking-level mapping and was translated to :minimal"
        }

      _ ->
        nil
    end
  end

  defp google_effort_advisory(_provider, _canonical_opts, _translated_opts), do: nil
end
