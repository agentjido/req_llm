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

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.CoreTest do
        use ReqLLM.ProviderTest.Core, provider: :anthropic
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
      @moduletag category: :core
      @moduletag provider: provider

      defp debug?, do: System.get_env("REQ_LLM_DEBUG") in ["1", "true"]

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          test "request encoding and response parsing" do
            require Logger

            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_basic"

            if debug?() do
              IO.puts("\n[CoreTest] model_spec=#{@model_spec}, model_name=#{model_name}")
              IO.puts("[CoreTest] fixture_name=#{fixture_name}, provider=#{@provider}")
            end

            Logger.debug("CoreTest: model_spec=#{@model_spec}, model_name=#{model_name}")
            Logger.debug("CoreTest: fixture_name=#{fixture_name}")
            Logger.debug("CoreTest: provider=#{@provider}")

            ReqLLM.generate_text(
              @model_spec,
              "Hello world!",
              fixture_opts(@provider, fixture_name, param_bundles(@provider).deterministic)
            )
            |> assert_basic_response()

            context =
              ReqLLM.Context.new([
                system("You are a helpful assistant."),
                user("Say hello")
              ])

            ReqLLM.generate_text(
              @model_spec,
              context,
              fixture_opts(
                @provider,
                "#{model_name}_system_msg",
                param_bundles(@provider).deterministic
              )
            )
            |> assert_basic_response()
          end

          test "parameter handling and constraints" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            ReqLLM.generate_text(
              @model_spec,
              "Write a very long story about dragons and adventures",
              fixture_opts(
                @provider,
                "#{model_name}_token_limit",
                param_bundles(@provider).minimal
              )
            )
            |> assert_basic_response()
            |> assert_text_length(200)

            ReqLLM.generate_text(
              @model_spec,
              "Tell me about the color blue",
              fixture_opts(@provider, "#{model_name}_creative", param_bundles(@provider).creative)
            )
            |> assert_basic_response()
          end
        end
      end
    end
  end
end
