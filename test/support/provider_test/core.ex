defmodule ReqLLM.ProviderTest.Core do
  @moduledoc """
  Core provider functionality tests.

  Verifies that ReqLLM properly:
  - Encodes generic requests into provider-specific format
  - Makes successful API calls
  - Returns properly normalized Response objects
  - Handles common parameters correctly

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
      @moduletag category: :core
      @moduletag provider: provider

      test "request encoding and response parsing" do
        # Test 1: Basic string prompt with deterministic params
        ReqLLM.generate_text(
          unquote(model),
          "Hello world!",
          fixture_opts(unquote(provider), "basic", param_bundles().deterministic)
        )
        |> assert_basic_response()

        # Test 2: System message context to verify complex request encoding
        context =
          ReqLLM.Context.new([
            system("You are a helpful assistant."),
            user("Say hello")
          ])

        ReqLLM.generate_text(
          unquote(model),
          context,
          fixture_opts(unquote(provider), "system_msg", param_bundles().deterministic)
        )
        |> assert_basic_response()
      end

      test "parameter handling and constraints" do
        # Test 1: Token limit enforcement
        ReqLLM.generate_text(
          unquote(model),
          "Write a very long story about dragons and adventures",
          fixture_opts(unquote(provider), "token_limit", param_bundles().minimal)
        )
        |> assert_basic_response()
        # Should be short due to max_tokens: 5
        |> assert_text_length(100)

        # Test 2: Temperature parameter (creative vs deterministic)
        ReqLLM.generate_text(
          unquote(model),
          "Tell me about the color blue",
          fixture_opts(unquote(provider), "creative", param_bundles().creative)
        )
        |> assert_basic_response()
      end
    end
  end
end
