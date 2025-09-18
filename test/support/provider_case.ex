defmodule ReqLLM.ProviderCase do
  @moduledoc """
  Case template for provider-level testing.

  Provides a consistent test environment and common setup for testing
  ReqLLM provider implementations at the low-level Req plugin API level.

  ## Usage

      defmodule ReqLLM.Providers.MyProviderTest do
        use ReqLLM.ProviderCase, provider: ReqLLM.Providers.MyProvider
      end

  ## Automatic Setup

  - Sets appropriate API key environment variables
  - Imports ProviderTestMacros for common test patterns
  - Provides access to ProviderTestHelpers
  """

  use ExUnit.CaseTemplate

  using(opts) do
    provider = Keyword.get(opts, :provider)

    quote do
      use ExUnit.Case, async: false

      import ReqLLM.ProviderTestHelpers
      import ReqLLM.ProviderTestMacros

      alias ReqLLM.ProviderTestHelpers

      @provider unquote(provider)

      setup do
        if @provider do
          env_key = ReqLLM.ProviderCase.env_key_for(@provider)
          System.put_env(env_key, "test-key-12345")
        end

        :ok
      end
    end
  end

  @doc """
  Determines the environment variable key for a provider's API key.
  """
  def env_key_for(provider) do
    if function_exported?(provider, :default_env_key, 0) do
      provider.default_env_key()
    else
      provider_id = provider.provider_id()
      "#{provider_id |> Atom.to_string() |> String.upcase()}_API_KEY"
    end
  end
end
