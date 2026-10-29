defmodule ReqLLM.Providers.ContractTest do
  use ExUnit.Case, async: true

  @contracts [
    {ReqLLM.Providers.AlibabaCN, :alibaba_cn, "https://dashscope.aliyuncs.com/compatible-mode/v1",
     "DASHSCOPE_API_KEY"},
    {ReqLLM.Providers.Alibaba, :alibaba, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
     "DASHSCOPE_API_KEY"},
    {ReqLLM.Providers.AmazonBedrock, :amazon_bedrock,
     "https://bedrock-runtime.{region}.amazonaws.com", "AWS_ACCESS_KEY_ID"},
    {ReqLLM.Providers.Anthropic, :anthropic, "https://api.anthropic.com", "ANTHROPIC_API_KEY"},
    {ReqLLM.Providers.AtlasCloud, :atlascloud, "https://api.atlascloud.ai/v1",
     "ATLASCLOUD_API_KEY"},
    {ReqLLM.Providers.CheaperInference, :cheaperinference, "https://api.cheaperinference.com/v1",
     "CHEAPERINFERENCE_API_KEY"},
    {ReqLLM.Providers.Cohere, :cohere, "https://api.cohere.com", "COHERE_API_KEY"},
    {ReqLLM.Providers.Deepseek, :deepseek, "https://api.deepseek.com", "DEEPSEEK_API_KEY"},
    {ReqLLM.Providers.FireworksAI, :fireworks_ai, "https://api.fireworks.ai/inference/v1",
     "FIREWORKS_API_KEY"},
    {ReqLLM.Providers.GitHubCopilot, :github_copilot, "https://api.githubcopilot.com",
     "COPILOT_GITHUB_TOKEN"},
    {ReqLLM.Providers.Google, :google, "https://generativelanguage.googleapis.com/v1beta",
     "GOOGLE_API_KEY"},
    {ReqLLM.Providers.Groq, :groq, "https://api.groq.com/openai/v1", "GROQ_API_KEY"},
    {ReqLLM.Providers.Meta, :meta, "https://api.meta.ai/v1", "MODEL_API_KEY"},
    {ReqLLM.Providers.Minimax, :minimax, "https://api.minimax.io/v1", "MINIMAX_API_KEY"},
    {ReqLLM.Providers.Mistral, :mistral, "https://api.mistral.ai/v1", "MISTRAL_API_KEY"},
    {ReqLLM.Providers.NearAI, :nearai, "https://cloud-api.near.ai/v1", "NEARAI_API_KEY"},
    {ReqLLM.Providers.OpenAICodex, :openai_codex, "https://chatgpt.com/backend-api", nil},
    {ReqLLM.Providers.OpenAI, :openai, "https://api.openai.com/v1", "OPENAI_API_KEY"},
    {ReqLLM.Providers.OpenRouter, :openrouter, "https://openrouter.ai/api/v1",
     "OPENROUTER_API_KEY"},
    {ReqLLM.Providers.Venice, :venice, "https://api.venice.ai/api/v1", "VENICE_API_KEY"},
    {ReqLLM.Providers.VLLM, :vllm, "http://localhost:8000/v1", "OPENAI_API_KEY"},
    {ReqLLM.Providers.XAI, :xai, "https://api.x.ai/v1", "XAI_API_KEY"},
    {ReqLLM.Providers.Zenmux, :zenmux, "https://zenmux.ai/api/v1", "ZENMUX_API_KEY"}
  ]

  @openai_compatible_contracts [
    {ReqLLM.Providers.AtlasCloud, :atlascloud, "qwen/qwen3.5-flash",
     "https://api.atlascloud.ai/v1"},
    {ReqLLM.Providers.CheaperInference, :cheaperinference, "gpt-5.4-mini",
     "https://api.cheaperinference.com/v1"},
    {ReqLLM.Providers.VLLM, :vllm, "test-model", "http://localhost:8000/v1"}
  ]

  for {provider, provider_id, base_url, env_key} <- @contracts do
    @provider provider
    @provider_id provider_id
    @base_url base_url
    @env_key env_key

    test "#{provider_id} exposes its configured identity" do
      assert @provider.provider_id() == @provider_id
      assert @provider.base_url() == @base_url

      if @env_key do
        assert apply(@provider, :default_env_key, []) == @env_key
      else
        refute function_exported?(@provider, :default_env_key, 0)
      end
    end

    test "#{provider_id} keeps provider options separate and extends the core schema" do
      provider_keys = @provider.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()
      overlap = MapSet.intersection(MapSet.new(provider_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"

      extended_keys = @provider.provider_extended_generation_schema().schema |> Keyword.keys()
      expected_keys = Enum.uniq(core_keys ++ provider_keys)
      missing_keys = expected_keys -- extended_keys

      assert missing_keys == [],
             "Extended provider schema is missing keys: #{inspect(missing_keys)}"
    end
  end

  for {provider, provider_id, model_id, base_url} <- @openai_compatible_contracts do
    @provider provider
    @provider_id provider_id
    @model_id model_id
    @base_url base_url

    defp compatible_model(unquote(provider_id), model_id) do
      %LLMDB.Model{
        id: model_id,
        model: model_id,
        provider_model_id: model_id,
        provider: unquote(provider_id),
        capabilities: %{chat: true, tools: %{enabled: true}},
        extra: %{wire: %{protocol: "openai_chat"}}
      }
    end

    test "#{provider_id} wires OpenAI-compatible chat requests" do
      model = compatible_model(@provider_id, @model_id)

      assert {:ok, %Req.Request{} = request} =
               @provider.prepare_request(:chat, model, "Hello", temperature: 0.7)

      assert request.method == :post
      assert request.url.path == "/chat/completions"
      assert request.options[:base_url] == @base_url

      assert {:ok, overridden} =
               @provider.prepare_request(:chat, model, "Hello",
                 base_url: "https://proxy.example.com/v1"
               )

      assert overridden.options[:base_url] == "https://proxy.example.com/v1"
    end

    test "#{provider_id} wires OpenAI-compatible authentication and pipeline steps" do
      model = compatible_model(@provider_id, @model_id)
      request = @provider.attach(Req.new(), model, api_key: "contract-key")

      assert request.headers["authorization"] == ["Bearer contract-key"]
      assert :llm_encode_body in Keyword.keys(request.request_steps)
      assert :llm_decode_response in Keyword.keys(request.response_steps)
    end

    test "#{provider_id} wires OpenAI-compatible request and response codecs" do
      model = compatible_model(@provider_id, @model_id)

      request = %Req.Request{
        options: [
          context: ReqLLM.ProviderCase.context_fixture(),
          model: model.model,
          stream: false,
          temperature: 0.7
        ]
      }

      encoded = @provider.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["model"] == @model_id
      assert is_list(body["messages"])
      assert body["stream"] == false
      assert body["temperature"] == 0.7

      response = %Req.Response{
        status: 200,
        body:
          ReqLLM.ProviderCase.openai_format_json_fixture(
            model: @model_id,
            content: "contract response"
          )
      }

      request = %Req.Request{
        options: [
          context: ReqLLM.ProviderCase.context_fixture(),
          model: @model_id,
          operation: :chat
        ]
      }

      {_request, decoded} = @provider.decode_response({request, response})

      assert %ReqLLM.Response{} = decoded.body
      assert ReqLLM.Response.text(decoded.body) == "contract response"
    end
  end
end
