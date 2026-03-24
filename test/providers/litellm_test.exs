defmodule ReqLLM.Providers.LiteLLMTest do
  @moduledoc """
  Provider-level tests for LiteLLM implementation.

  Tests the provider contract and wiring without making live API calls.
  LiteLLM is OpenAI-compatible so tests focus on configuration and routing.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.LiteLLM

  alias ReqLLM.Providers.LiteLLM

  defp litellm_model(model_id \\ "test-model", opts \\ []) do
    %LLMDB.Model{
      id: "litellm:#{model_id}",
      model: model_id,
      name: Keyword.get(opts, :name, "LiteLLM Test Model"),
      provider: :litellm,
      family: Keyword.get(opts, :family, "test"),
      capabilities: Keyword.get(opts, :capabilities, %{chat: true, tools: %{enabled: true}}),
      limits: Keyword.get(opts, :limits, %{context: 32_768, output: 4096})
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert LiteLLM.provider_id() == :litellm
      assert is_binary(LiteLLM.base_url())
      assert LiteLLM.base_url() == "http://localhost:4000"
    end

    test "provider uses LITELLM_API_KEY by default" do
      assert LiteLLM.default_env_key() == "LITELLM_API_KEY"
    end

    test "provider schema is empty (pure OpenAI-compatible)" do
      schema_keys = LiteLLM.provider_schema().schema |> Keyword.keys()
      assert schema_keys == []
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = LiteLLM.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      model = litellm_model()
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = LiteLLM.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "prepare_request for :embedding creates /embeddings request" do
      model = litellm_model("embedding-model", capabilities: %{embeddings: true})
      text = "Hello world"

      {:ok, request} = LiteLLM.prepare_request(:embedding, model, text, [])

      assert %Req.Request{} = request
      assert request.url.path == "/embeddings"
      assert request.method == :post
    end

    test "prepare_request rejects unsupported operations" do
      model = litellm_model()
      context = context_fixture()

      {:error, error} = LiteLLM.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      model = litellm_model()
      request = Req.new()

      attached = LiteLLM.attach(request, model, [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")
    end

    test "attach adds pipeline steps" do
      model = litellm_model()
      request = Req.new()

      attached = LiteLLM.attach(request, model, [])

      request_steps = Keyword.keys(attached.request_steps)
      response_steps = Keyword.keys(attached.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end
  end

  describe "base_url configuration" do
    test "uses default base_url when not overridden" do
      model = litellm_model()
      {:ok, request} = LiteLLM.prepare_request(:chat, model, "Hello", [])

      assert request.options[:base_url] == "http://localhost:4000"
    end

    test "respects base_url option override" do
      model = litellm_model()
      custom_url = "https://litellm.example.com"
      {:ok, request} = LiteLLM.prepare_request(:chat, model, "Hello", base_url: custom_url)

      assert request.options[:base_url] == custom_url
    end
  end

  describe "body encoding" do
    test "encode_body produces valid OpenAI-compatible JSON" do
      model = litellm_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = LiteLLM.encode_body(mock_request)

      assert is_binary(updated_request.body)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "test-model"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
      assert decoded["stream"] == false
    end
  end
end
