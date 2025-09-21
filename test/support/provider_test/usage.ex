defmodule ReqLLM.ProviderTest.Usage do
  @moduledoc """
  Usage calculation provider functionality tests.

  Verifies that ReqLLM properly:
  - Calculates input, output, and total costs from API usage data
  - Handles cached token costs for providers that support it (OpenAI)
  - Gracefully handles providers without cached token support (Groq)
  - Provides accurate usage metrics in Response objects

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with LIVE=true.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    quote bind_quoted: [provider: provider, model: model] do
      use ExUnit.Case, async: false

      import ReqLLM.Context
      import ReqLLM.ProviderTestHelpers

      @moduletag :capture_log
      @moduletag :coverage
      @moduletag category: :usage
      @moduletag provider: provider

      test "basic usage calculation" do
        {:ok, response} =
          ReqLLM.generate_text(
            unquote(model),
            "Count from 1 to 10",
            Keyword.merge([fixture: "basic_usage"], param_bundles().deterministic)
          )

        # Verify response and usage structure
        assert %ReqLLM.Response{} = response
        assert ReqLLM.Response.text(response) != ""
        assert is_map(response.usage)

        input_tokens = response.usage[:input_tokens] || response.usage[:input]
        output_tokens = response.usage[:output_tokens] || response.usage[:output]

        assert is_number(input_tokens) and input_tokens > 0
        assert is_number(output_tokens) and output_tokens >= 0

        # Verify cost calculations if model has pricing
        case ReqLLM.Model.from(unquote(model)) do
          {:ok, %ReqLLM.Model{cost: cost_map}} when is_map(cost_map) ->
            assert is_number(response.usage.input_cost) and response.usage.input_cost >= 0
            assert is_number(response.usage.output_cost) and response.usage.output_cost >= 0
            assert is_number(response.usage.total_cost) and response.usage.total_cost >= 0

            # Use approximate equality for floating point arithmetic
            expected = response.usage.input_cost + response.usage.output_cost
            assert abs(response.usage.total_cost - expected) < 0.00001

          _ ->
            refute Map.has_key?(response.usage, :input_cost)
        end
      end

      test "cached token handling" do
        {:ok, response} =
          ReqLLM.generate_text(
            unquote(model),
            "Explain quantum computing in simple terms",
            Keyword.merge([fixture: "cached_tokens"], param_bundles().deterministic)
          )

        assert is_map(response.usage)

        # OpenAI may provide cached_tokens, others should handle gracefully
        case unquote(provider) do
          :openai ->
            cached_tokens = response.usage[:cached_tokens] || 0
            assert is_number(cached_tokens) and cached_tokens >= 0

          _ ->
            # Other providers don't support cached tokens - verify normal usage
            input_tokens = response.usage[:input_tokens] || response.usage[:input]
            assert is_number(input_tokens) and input_tokens > 0
        end
      end

      test "cost calculations with various token counts" do
        {:ok, response} =
          ReqLLM.generate_text(
            unquote(model),
            "Hi there!",
            Keyword.merge(
              [fixture: "cost_calculation", max_tokens: 10],
              param_bundles().deterministic
            )
          )

        assert is_map(response.usage)
        input_tokens = response.usage[:input_tokens] || response.usage[:input]
        output_tokens = response.usage[:output_tokens] || response.usage[:output]

        assert is_number(input_tokens) and input_tokens > 0
        assert is_number(output_tokens) and output_tokens >= 0

        # Test cost calculations if pricing available
        case ReqLLM.Model.from(unquote(model)) do
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
