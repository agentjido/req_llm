defmodule ReqLLM.ProvidersTest do
  use ExUnit.Case, async: true

  describe "list/0" do
    test "returns list of registered provider atoms" do
      providers = ReqLLM.Providers.list()

      assert is_list(providers)
      assert :openai in providers
      assert :anthropic in providers
      assert :groq in providers
    end
  end

  describe "get/1" do
    test "returns provider module for valid provider" do
      assert {:ok, ReqLLM.Providers.OpenAI} = ReqLLM.Providers.get(:openai)
      assert {:ok, ReqLLM.Providers.Anthropic} = ReqLLM.Providers.get(:anthropic)
    end

    test "returns error for unknown provider" do
      assert {:error, %ReqLLM.Error.Invalid.Provider{provider: :unknown_provider}} =
               ReqLLM.Providers.get(:unknown_provider)
    end
  end

  describe "register/1 and unregister/1" do
    test "register returns error for non-Provider module" do
      defmodule NotAProvider do
        def hello, do: :world
      end

      assert {:error, %ReqLLM.Error.Invalid.Provider{}} =
               ReqLLM.Providers.register(NotAProvider)
    end
  end
end
