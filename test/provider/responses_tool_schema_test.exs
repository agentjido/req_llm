defmodule ReqLLM.Providers.ResponsesToolSchemaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Tool

  for {provider, module} <- [
        openai: ReqLLM.Providers.OpenAI,
        azure: ReqLLM.Providers.Azure,
        meta: ReqLLM.Providers.Meta,
        xai: ReqLLM.Providers.XAI,
        openai_codex: ReqLLM.Providers.OpenAICodex,
        amazon_bedrock: ReqLLM.Providers.AmazonBedrock
      ] do
    test "#{provider} preserves tool schemas in buffered and streaming Responses requests" do
      {model, provider_opts} = provider_config(unquote(provider))
      provider = unquote(module)
      context = Context.new([Context.user("Get the weather in London")])

      parameters = %{
        "type" => "object",
        "$defs" => %{"location" => %{"type" => "string"}},
        "properties" => %{
          "location" => %{"$ref" => "#/$defs/location"},
          "units" => %{"type" => "string"}
        },
        "required" => ["location"],
        "additionalProperties" => true
      }

      tool =
        Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: parameters,
          callback: fn args -> {:ok, args} end
        )

      strict_tool = %{tool | name: "get_weather_strict", strict: true}
      opts = Keyword.put(provider_opts, :tools, [tool, strict_tool])

      assert {:ok, request} = provider.prepare_request(:chat, model, context, opts)
      buffered = request |> provider.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert {:ok, request} = provider.attach_stream(model, context, opts, ReqLLM.Finch)
      streamed = Jason.decode!(request.body)

      for body <- [buffered, streamed] do
        assert [%{"type" => "function"} = non_strict, strict] = body["tools"]
        assert non_strict["strict"] == false
        assert non_strict["parameters"] == parameters
        assert strict["strict"] == true
        assert Enum.sort(strict["parameters"]["required"]) == ["location", "units"]
        assert strict["parameters"]["additionalProperties"] == false
      end

      assert buffered["tools"] == streamed["tools"]
    end
  end

  defp provider_config(:openai) do
    {ReqLLM.model!("openai:gpt-5"), [api_key: "test-key"]}
  end

  defp provider_config(:azure) do
    {ReqLLM.model!("azure:gpt-5"),
     [api_key: "test-key", base_url: "https://example.openai.azure.com/openai/v1"]}
  end

  defp provider_config(:meta) do
    {ReqLLM.model!("meta:muse-spark-1.1"), [api_key: "test-key"]}
  end

  defp provider_config(:xai) do
    {ReqLLM.model!("xai:grok-4-fast-reasoning"),
     [api_key: "test-key", provider_options: [xai_api: :responses]]}
  end

  defp provider_config(:openai_codex) do
    {ReqLLM.model!("openai_codex:gpt-5.3-codex-spark"),
     [
       provider_options: [
         auth_mode: :oauth,
         access_token: "test-token",
         chatgpt_account_id: "test-account"
       ]
     ]}
  end

  defp provider_config(:amazon_bedrock) do
    {ReqLLM.model!(%{provider: :amazon_bedrock, id: "openai.gpt-5.6-terra"}),
     [api_key: "test-key", region: "us-east-1", provider_options: [endpoint: :mantle]]}
  end
end
