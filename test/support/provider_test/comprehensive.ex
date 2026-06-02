defmodule ReqLLM.ProviderTest.Comprehensive do
  @moduledoc """
  Comprehensive per-model provider tests.

  Generates registry-backed provider scenarios for each selected text model.
  Scenario modules own prompts, fixture names, capability applicability, and
  assertions; this macro owns ExUnit model/provider/scenario tags.

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.ComprehensiveTest do
        use ReqLLM.ProviderTest.Comprehensive, provider: :anthropic
      end

  This will generate all tests for models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  def supports_object_generation?(model_spec) do
    ReqLLM.Test.Scenarios.Capabilities.supports_object_generation?(model_spec)
  end

  def supports_streaming_object_generation?(model_spec) do
    ReqLLM.Test.Scenarios.Capabilities.supports_streaming_object_generation?(model_spec)
  end

  def supports_tool_calling?(model_spec) do
    ReqLLM.Test.Scenarios.Capabilities.supports_tool_calling?(model_spec)
  end

  def supports_reasoning?(model_spec) do
    ReqLLM.Test.Scenarios.Capabilities.supports_reasoning?(model_spec)
  end

  def supports_forced_tool_choice?(model_spec) do
    ReqLLM.Test.Scenarios.Capabilities.supports_forced_tool_choice?(model_spec)
  end

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag provider: to_string(provider)
      @moduletag timeout: 300_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :text)

      setup_all do
        LLMDB.load(allow: :all, custom: %{})
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        {:ok, model} = ReqLLM.model(model_spec)
        scenario_modules = ReqLLM.Test.Scenarios.for_model(model)

        describe "#{model_spec}" do
          @describetag model: model_spec |> String.split(":", parts: 2) |> List.last()

          for scenario_module <- scenario_modules do
            @scenario_module scenario_module
            @tag scenario: scenario_module.id()

            if scenario_module.id() == :token_limit do
              @tag timeout: 600_000
            end

            test scenario_module.name() do
              ReqLLM.Test.Scenario.execute(
                @scenario_module,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end
          end
        end
      end
    end
  end
end
