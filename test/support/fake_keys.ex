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

  Keys are installed as system environment variables.
  """
  def install! do
    if ReqLLM.Test.Env.fixtures_mode() != :record do
      providers = ReqLLM.Providers.list()

      for provider <- providers do
        env_var = ReqLLM.Keys.env_var_name(provider)
        config_key = ReqLLM.Keys.config_key(provider)

        if System.get_env(env_var) in [nil, ""] and
             Application.get_env(:req_llm, config_key) in [nil, ""] do
          System.put_env(env_var, "test-key-#{provider}")
        end
      end
    end
  end
end
