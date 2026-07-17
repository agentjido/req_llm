defmodule ReqLLM.Provider.ReasoningTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Provider.Options
  alias ReqLLM.Provider.Reasoning
  alias ReqLLM.Providers.{Anthropic, Google, OpenAI, XAI}

  describe "normalization" do
    test "preserves the documented legacy aliases" do
      assert Reasoning.normalize_options(reasoning: true) == [reasoning_effort: :medium]
      assert Reasoning.normalize_options(reasoning: "high") == [reasoning_effort: :high]
      assert Reasoning.normalize_options(reasoning: "max") == [reasoning_effort: :max]
      assert Reasoning.normalize_options(reasoning: "none") == [reasoning_effort: :none]
      assert Reasoning.normalize_options(reasoning: "auto") == []
      assert Reasoning.normalize_options(reasoning: false) == []

      assert Reasoning.normalize_options(reasoning: "low", reasoning_effort: :high) ==
               [reasoning_effort: :high]
    end

    test "uses one effort normalizer for accepted string values" do
      for effort <- [:none, :minimal, :low, :medium, :high, :xhigh, :max, :default] do
        assert Reasoning.normalize_effort(Atom.to_string(effort)) == effort
        assert Reasoning.normalize_effort(effort) == effort
      end

      assert Reasoning.normalize_effort("provider-native") == "provider-native"
    end
  end

  describe "request compatibility" do
    test "canonical and legacy aliases produce identical processed options" do
      cases = [
        {OpenAI, "openai:gpt-5"},
        {Anthropic, "anthropic:claude-sonnet-4-5"},
        {Google, "google:gemini-2.5-pro"},
        {XAI, "xai:grok-4"}
      ]

      capture_log(fn ->
        for {provider, model_spec} <- cases do
          model = ReqLLM.model!(model_spec)

          assert {:ok, canonical} =
                   Options.process(provider, :chat, model, reasoning_effort: :high)

          assert {:ok, legacy} = Options.process(provider, :chat, model, reasoning: "high")
          assert canonical == legacy
        end
      end)
    end

    test "preserves accepted OpenAI and xAI string efforts" do
      cases = [{OpenAI, "openai:gpt-5"}, {XAI, "xai:grok-4"}]

      capture_log(fn ->
        for {provider, model_spec} <- cases do
          model = ReqLLM.model!(model_spec)

          assert {:ok, atom_options} =
                   Options.process(provider, :chat, model, reasoning_effort: :high)

          assert {:ok, string_options} =
                   Options.process(provider, :chat, model, reasoning_effort: "high")

          assert Keyword.delete(atom_options, :telemetry_original_opts) ==
                   Keyword.delete(string_options, :telemetry_original_opts)

          assert atom_options[:telemetry_original_opts][:reasoning_effort] == :high
          assert string_options[:telemetry_original_opts][:reasoning_effort] == "high"
        end
      end)
    end

    test "omitted reasoning controls do not add provider reasoning fields" do
      cases = [
        {OpenAI, "openai:gpt-4o-mini", [:reasoning_effort, :reasoning_token_budget]},
        {Anthropic, "anthropic:claude-sonnet-4-5", [:thinking]},
        {Google, "google:gemini-2.5-pro", [:google_thinking_budget, :google_thinking_level]},
        {XAI, "xai:grok-4", [:reasoning_effort, :reasoning_token_budget]}
      ]

      capture_log(fn ->
        for {provider, model_spec, absent_keys} <- cases do
          assert {:ok, processed} =
                   Options.process(provider, :chat, ReqLLM.model!(model_spec), [])

          for key <- absent_keys do
            refute Keyword.has_key?(processed, key)
          end
        end
      end)
    end

    test "preserves existing canonical precedence over native reasoning controls" do
      anthropic = ReqLLM.model!("anthropic:claude-sonnet-4-5")

      assert {:ok, anthropic_opts} =
               Options.process(Anthropic, :chat, anthropic,
                 reasoning_effort: :low,
                 provider_options: [thinking: %{type: "enabled", budget_tokens: 7_777}]
               )

      assert anthropic_opts[:thinking] == %{type: "enabled", budget_tokens: 1_024}

      google = ReqLLM.model!("google:gemini-2.5-pro")

      assert {:ok, google_opts} =
               Options.process(Google, :chat, google,
                 reasoning_effort: :low,
                 provider_options: [google_thinking_budget: 7_777]
               )

      assert google_opts[:google_thinking_budget] == 4_096
    end

    test "preserves invalid reasoning error shapes" do
      cases = [
        {OpenAI, "openai:gpt-5"},
        {Anthropic, "anthropic:claude-sonnet-4-5"},
        {Google, "google:gemini-2.5-pro"},
        {XAI, "xai:grok-4"}
      ]

      for {provider, model_spec} <- cases do
        model = ReqLLM.model!(model_spec)

        assert {:error,
                %ReqLLM.Error.Unknown.Unknown{
                  error: %NimbleOptions.ValidationError{}
                }} = Options.process(provider, :chat, model, reasoning_effort: :invalid)

        assert {:error,
                %ReqLLM.Error.Unknown.Unknown{
                  error: %NimbleOptions.ValidationError{}
                }} = Options.process(provider, :chat, model, reasoning_token_budget: 0)
      end
    end
  end

  describe "structured advisories" do
    test "reports ignored token budgets without making them enforceable" do
      model = ReqLLM.model!("openai:gpt-4.1")

      assert [
               %{
                 kind: :ignored,
                 option: :reasoning_token_budget,
                 message: message
               }
             ] =
               Reasoning.advisories(
                 OpenAI,
                 model,
                 [reasoning_token_budget: 4_096],
                 []
               )

      assert message =~ "OpenAI"
      assert message =~ "ignored"

      assert capture_log(fn ->
               assert {:ok, _processed} =
                        Options.process(OpenAI, :chat, model,
                          reasoning_token_budget: 4_096,
                          on_unsupported: :error
                        )
             end) =~ ":reasoning_token_budget"

      assert capture_log(fn ->
               assert {:ok, _processed} =
                        Options.process(OpenAI, :chat, model,
                          reasoning_token_budget: 4_096,
                          on_unsupported: :ignore
                        )
             end) == ""
    end

    test "reports deterministic Gemini clamping and lossy mappings" do
      model = ReqLLM.model!("google:gemini-3-flash-preview")

      assert [
               %{kind: :clamped, option: :reasoning_effort},
               %{kind: :clamped, option: :reasoning_effort},
               %{kind: :lossy, option: :reasoning_effort}
             ] =
               Reasoning.advisories(
                 Google,
                 model,
                 [reasoning_effort: :xhigh],
                 google_thinking_level: :high
               ) ++
                 Reasoning.advisories(
                   Google,
                   model,
                   [reasoning_effort: :max],
                   google_thinking_level: :high
                 ) ++
                 Reasoning.advisories(
                   Google,
                   model,
                   [reasoning_effort: :none],
                   google_thinking_level: :minimal
                 )
    end

    test "does not mistake an unrelated native budget for the canonical budget" do
      model = ReqLLM.model!("anthropic:claude-sonnet-4-5")

      assert [
               %{
                 kind: :ignored,
                 option: :reasoning_token_budget
               }
             ] =
               Reasoning.advisories(
                 Anthropic,
                 model,
                 [reasoning_token_budget: 4_096, thinking: %{budget_tokens: 7_777}],
                 thinking: %{budget_tokens: 7_777}
               )
    end

    test "reports lossy nested legacy effort translations before pre-validation removes them" do
      model = ReqLLM.model!("google:gemini-3-flash-preview")

      log =
        capture_log(fn ->
          assert {:ok, processed} =
                   Options.process(Google, :chat, model,
                     provider_options: [reasoning_effort: "xhigh"]
                   )

          assert processed[:google_thinking_level] == :high
        end)

      assert log =~ ":reasoning_effort :xhigh was clamped"
    end

    test "exposes advisories through sanitized request planning" do
      assert {:ok, openai_plan} =
               ReqLLM.plan("openai:gpt-5", :chat, reasoning_token_budget: 4_096)

      assert Enum.any?(openai_plan.warnings, &String.contains?(&1, "ignored"))
    end
  end
end
