defmodule ReqLLM.ProvidersTest do
  use ExUnit.Case, async: true

  defmodule ProviderWithoutId do
    @behaviour ReqLLM.Provider

    def default_base_url, do: "https://example.com"
    def supported_provider_options, do: []
    def prepare_request(_operation, _model, _data, _opts), do: {:error, :not_implemented}
    def attach(request, _model, _opts), do: request
    def encode_body(request), do: request
    def decode_response(request_response), do: request_response
  end

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

    test "registers provider without provider_id/0 using module atom fallback" do
      assert {:ok, provider_id} = ReqLLM.Providers.register(ProviderWithoutId)
      assert provider_id == ProviderWithoutId
      assert {:ok, ProviderWithoutId} = ReqLLM.Providers.get(provider_id)
      assert :ok = ReqLLM.Providers.unregister(provider_id)
    end
  end
end
