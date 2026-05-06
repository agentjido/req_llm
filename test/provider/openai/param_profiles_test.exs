defmodule Provider.OpenAI.ParamProfilesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.ParamProfiles

  describe "steps_for/2" do
    test "always includes canonical reasoning transforms" do
      steps = ParamProfiles.steps_for(:chat, model(id: "gpt-4.1"))
      translate_reasoning_effort = translation_fun(steps)

      assert Enum.any?(steps, &match?({:drop, :reasoning_token_budget, nil}, &1))
      assert translate_reasoning_effort.(:none) == "none"
      assert translate_reasoning_effort.(:minimal) == "minimal"
      assert translate_reasoning_effort.(:low) == "low"
      assert translate_reasoning_effort.(:medium) == "medium"
      assert translate_reasoning_effort.(:high) == "high"
      assert translate_reasoning_effort.(:xhigh) == "xhigh"
      assert translate_reasoning_effort.(:default) == nil
      assert translate_reasoning_effort.("custom") == "custom"
    end

    test "adds reasoning and no sampling profiles for o-series models" do
      steps = ParamProfiles.steps_for(:chat, model(id: "o3-mini"))

      assert Enum.any?(steps, &match?({:rename, :max_tokens, :max_completion_tokens, _}, &1))
      assert Enum.any?(steps, &match?({:drop, :temperature, _}, &1))
      assert Enum.any?(steps, &match?({:drop, :top_p, _}, &1))
      assert Enum.any?(steps, &match?({:drop, :top_k, _}, &1))
    end

    test "adds reasoning profile from atom-key capabilities" do
      steps =
        ParamProfiles.steps_for(
          :chat,
          raw_model(id: "custom-openai", capabilities: %{reasoning: true})
        )

      assert Enum.any?(steps, &match?({:rename, :max_tokens, :max_completion_tokens, _}, &1))
      refute Enum.any?(steps, &match?({:drop, :top_p, _}, &1))
    end

    test "adds reasoning profile from capabilities map" do
      steps =
        ParamProfiles.steps_for(
          :chat,
          raw_model(id: "custom-openai", capabilities: %{reasoning: %{enabled: true}})
        )

      assert Enum.any?(steps, &match?({:rename, :max_tokens, :max_completion_tokens, _}, &1))
    end

    test "does not apply chat-only profiles to other operations" do
      steps = ParamProfiles.steps_for(:embedding, model(id: "o3-mini"))

      refute Enum.any?(steps, &match?({:rename, :max_tokens, :max_completion_tokens, _}, &1))
      refute Enum.any?(steps, &match?({:drop, :temperature, _}, &1))
      refute Enum.any?(steps, &match?({:drop, :top_p, _}, &1))
      refute Enum.any?(steps, &match?({:drop, :top_k, _}, &1))
    end
  end

  defp model(attrs) do
    attrs = Enum.into(attrs, %{})

    LLMDB.Model.new!(
      Map.merge(
        %{
          provider: :openai,
          id: "gpt-4.1"
        },
        attrs
      )
    )
  end

  defp raw_model(attrs) do
    attrs = Enum.into(attrs, %{})

    struct(
      LLMDB.Model,
      Map.merge(
        %{
          provider: :openai,
          id: "gpt-4.1"
        },
        attrs
      )
    )
  end

  defp translation_fun(steps) do
    Enum.find_value(steps, fn
      {:transform, :reasoning_effort, fun, nil} -> fun
      _ -> nil
    end)
  end
end
