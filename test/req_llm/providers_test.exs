defmodule ReqLLM.ProvidersTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers

  setup do
    Providers.initialize()
    :ok
  end

  describe "list/0" do
    test "returns built-in providers" do
      providers = Providers.list()

      assert :openai in providers
      assert :anthropic in providers
      assert :google in providers
    end
  end

  describe "get/1" do
    test "returns module for valid provider" do
      assert {:ok, ReqLLM.Providers.OpenAI} = Providers.get(:openai)
    end

    test "returns error for unknown provider" do
      assert {:error, %ReqLLM.Error.Invalid.Provider{}} = Providers.get(:nonexistent)
    end
  end

  describe "register/1" do
    test "registers a valid custom provider module" do
      assert {:ok, :test_custom} = Providers.register(ReqLLM.ProvidersTest.TestProvider)
      assert {:ok, ReqLLM.ProvidersTest.TestProvider} = Providers.get(:test_custom)
      assert :test_custom in Providers.list()

      Providers.unregister(:test_custom)
    end

    test "returns error for module without Provider behaviour" do
      assert {:error, _} = Providers.register(ReqLLM.ProvidersTest.NotAProvider)
    end
  end

  describe "unregister/1" do
    test "removes a registered provider" do
      {:ok, :removable} = Providers.register(ReqLLM.ProvidersTest.RemovableProvider)
      assert :removable in Providers.list()

      :ok = Providers.unregister(:removable)
      refute :removable in Providers.list()
    end
  end

  describe "custom_providers config" do
    test "loads custom providers from config at initialization" do
      original_config = Application.get_env(:req_llm, :custom_providers, [])

      try do
        Application.put_env(:req_llm, :custom_providers, [
          ReqLLM.ProvidersTest.ConfiguredProvider
        ])

        Providers.initialize()

        assert :configured_custom in Providers.list()
        assert {:ok, ReqLLM.ProvidersTest.ConfiguredProvider} = Providers.get(:configured_custom)
      after
        Application.put_env(:req_llm, :custom_providers, original_config)
        Providers.initialize()
      end
    end
  end
end

defmodule ReqLLM.ProvidersTest.TestProvider do
  use ReqLLM.Provider,
    id: :test_custom,
    default_base_url: "https://test.example.com"
end

defmodule ReqLLM.ProvidersTest.RemovableProvider do
  use ReqLLM.Provider,
    id: :removable,
    default_base_url: "https://test.example.com"
end

defmodule ReqLLM.ProvidersTest.ConfiguredProvider do
  use ReqLLM.Provider,
    id: :configured_custom,
    default_base_url: "https://test.example.com"
end

defmodule ReqLLM.ProvidersTest.NotAProvider do
  def hello, do: :world
end
