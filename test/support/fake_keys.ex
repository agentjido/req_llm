defmodule ReqLLM.TestSupport.FakeKeys do
  @moduledoc """
  Test helper that injects fake API keys when LIVE mode is not enabled.

  This ensures unit tests have access to mock API keys without polluting
  production code with test-specific logic.
  """

  @doc """
  Installs fake API keys for all registered providers when not in record mode.

  Keys are only injected if:
  1. Fixture mode is not set to :record
  2. No real key exists in environment variables or application config

  Keys are installed via JidoKeys if available, otherwise as environment variables.
  """
  def install! do
    if ReqLLM.Test.Env.fixtures_mode() != :record do
      providers = ReqLLM.Provider.Registry.list_providers()

      for provider <- providers do
        env_var = ReqLLM.Keys.env_var_name(provider)
        config_key = ReqLLM.Keys.config_key(provider)

        # Only inject if no real key exists
        if System.get_env(env_var) in [nil, ""] and
             Application.get_env(:req_llm, config_key) in [nil, ""] do
          if Code.ensure_loaded?(JidoKeys) do
            JidoKeys.put(env_var, "test-key-#{provider}")
          else
            System.put_env(env_var, "test-key-#{provider}")
          end
        end
      end
    end
  end
end
