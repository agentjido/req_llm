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
end
