defmodule ReqLLM.ProviderTest.Usage do
  @moduledoc """
  Usage calculation provider functionality tests.

  Verifies that ReqLLM properly:
  - Calculates input, output, and total costs from API usage data
  - Handles cached token costs for providers that support it (OpenAI)
  - Gracefully handles providers without cached token support (Groq)
  - Provides accurate usage metrics in Response objects

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.UsageTest do
        use ReqLLM.ProviderTest.Usage, provider: :anthropic
      end

  This will generate tests for all models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ReqLLM.Context
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :usage
      @moduletag provider: provider

      defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          test "basic usage calculation" do
            require Logger

            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_basic_usage"

            if debug?() do
              IO.puts("\n[UsageTest] model_spec=#{@model_spec}, model_name=#{model_name}")
              IO.puts("[UsageTest] fixture_name=#{fixture_name}, provider=#{@provider}")
            end

            Logger.debug("UsageTest: model_spec=#{@model_spec}")
            Logger.debug("UsageTest: fixture_name=#{fixture_name}")

            {:ok, response} =
              ReqLLM.generate_text(
                @model_spec,
                "Count from 1 to 10",
                fixture_opts(@provider, fixture_name, param_bundles(@provider).deterministic)
              )

            assert %ReqLLM.Response{} = response
            assert ReqLLM.Response.text(response) != ""
            assert is_map(response.usage)

            input_tokens = response.usage[:input_tokens] || response.usage[:input]
            output_tokens = response.usage[:output_tokens] || response.usage[:output]

            assert is_number(input_tokens) and input_tokens > 0
            assert is_number(output_tokens) and output_tokens >= 0

            case ReqLLM.Model.from(@model_spec) do
              {:ok, %ReqLLM.Model{cost: cost_map}} when is_map(cost_map) ->
                assert is_number(response.usage.input_cost) and response.usage.input_cost >= 0
                assert is_number(response.usage.output_cost) and response.usage.output_cost >= 0
                assert is_number(response.usage.total_cost) and response.usage.total_cost >= 0

                expected = response.usage.input_cost + response.usage.output_cost
                assert abs(response.usage.total_cost - expected) < 0.00001

              _ ->
                refute Map.has_key?(response.usage, :input_cost)
            end
          end

          test "cached token handling" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_cached_tokens"

            {:ok, response} =
              ReqLLM.generate_text(
                @model_spec,
                "Explain quantum computing in simple terms",
                fixture_opts(@provider, fixture_name, param_bundles(@provider).deterministic)
              )

            assert is_map(response.usage)

            case @provider do
              :openai ->
                cached_tokens = response.usage[:cached_tokens] || 0
                assert is_number(cached_tokens) and cached_tokens >= 0

              _ ->
                input_tokens = response.usage[:input_tokens] || response.usage[:input]
                assert is_number(input_tokens) and input_tokens > 0
            end
          end

          test "cost calculations with various token counts" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_cost_calculation"

            {:ok, response} =
              ReqLLM.generate_text(
                @model_spec,
                "Hi there!",
                fixture_opts(
                  @provider,
                  fixture_name,
                  Keyword.merge([max_tokens: 10], param_bundles(@provider).deterministic)
                )
              )

            assert is_map(response.usage)
            input_tokens = response.usage[:input_tokens] || response.usage[:input]
            output_tokens = response.usage[:output_tokens] || response.usage[:output]

            assert is_number(input_tokens) and input_tokens > 0
            assert is_number(output_tokens) and output_tokens >= 0

            case ReqLLM.Model.from(@model_spec) do
              {:ok, %ReqLLM.Model{cost: cost_map}} when is_map(cost_map) ->
                assert response.usage.total_cost >= 0
                assert response.usage.input_cost >= 0
                assert response.usage.output_cost >= 0

              _ ->
                :ok
            end
          end
        end
      end
    end
  end
end
