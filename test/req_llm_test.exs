defmodule ReqLLMTest do
  use ExUnit.Case, async: true

  describe "model/1 top-level API" do
    test "resolves anthropic model string spec" do
      assert {:ok, %LLMDB.Model{provider: :anthropic, id: "claude-3-5-sonnet-20240620"}} =
               ReqLLM.model("anthropic:claude-3-5-sonnet-20240620")
    end

    test "resolves anthropic model with haiku" do
      assert {:ok, %LLMDB.Model{provider: :anthropic, id: "claude-3-haiku-20240307"}} =
               ReqLLM.model("anthropic:claude-3-haiku")
    end

    test "resolves ElevenLabs model string spec" do
      assert {:ok, %LLMDB.Model{provider: :elevenlabs, id: "eleven_multilingual_v2"}} =
               ReqLLM.model("elevenlabs:eleven_multilingual_v2")
    end

    test "returns error for invalid provider" do
      assert {:error, _} = ReqLLM.model("invalid_provider:some-model")
    end

    test "returns error for malformed spec" do
      assert {:error, _} = ReqLLM.model("invalid-format")
    end

    test "normalizes codex model wire protocol to openai_responses" do
      {:ok, model} = ReqLLM.model("openai:gpt-5.3-codex")

      assert get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) == "openai_responses"
    end

    test "resolves openai_codex string spec via openai catalog fallback" do
      assert {:ok,
              %LLMDB.Model{
                provider: :openai_codex,
                id: "gpt-5.3-codex-spark",
                provider_model_id: "gpt-5.3-codex-spark"
              } = model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      assert get_in(model, [Access.key(:extra, %{}), :wire, :protocol]) ==
               "openai_codex_responses"
    end

    test "resolves openai_codex tuple spec via openai catalog fallback" do
      assert {:ok,
              %LLMDB.Model{
                provider: :openai_codex,
                id: "gpt-5.3-codex-spark"
              }} =
               ReqLLM.model({:openai_codex, id: "gpt-5.3-codex-spark"})
    end

    test "merges native OpenAI pricing components into OpenRouter models" do
      {:ok, model} = ReqLLM.model("openrouter:openai/gpt-4o")

      assert component_rate(model.pricing, "token.input") == 2.5
      assert component_rate(model.pricing, "tool.web_search") == 10.0
      assert component_rate(model.pricing, "tool.file_search") == 2.5
    end

    test "preserves OpenRouter Google token pricing while adding native tool components" do
      {:ok, model} = ReqLLM.model("openrouter:google/gemini-2.5-flash")

      assert component_rate(model.pricing, "token.cache_read") == 0.0375
      assert component_rate(model.pricing, "tool.web_search") == 35.0
    end

    test "adds native xAI tool pricing to Azure-hosted Grok models" do
      {:ok, model} = ReqLLM.model("azure:grok-3-mini")

      assert component_rate(model.pricing, "token.reasoning") == 0.5
      assert component_rate(model.pricing, "tool.x_search") == 5.0
      assert component_rate(model.pricing, "tool.code_execution") == 5.0
    end

    test "adds native Anthropic tool pricing to Google Vertex Claude models" do
      {:ok, model} = ReqLLM.model("google_vertex:claude-sonnet-4@20250514")

      assert component_rate(model.pricing, "token.cache_write") == 3.75
      assert component_rate(model.pricing, "tool.web_search") == 10.0
    end

    test "adds native Anthropic tool pricing to Bedrock Claude models" do
      {:ok, model} = ReqLLM.model("amazon_bedrock:anthropic.claude-3-5-sonnet-20240620-v1:0")

      assert component_rate(model.pricing, "tool.web_search") == 10.0
    end
  end

  describe "model/1 with map-based specs (custom providers)" do
    test "creates model from map with id and provider" do
      assert {:ok, %LLMDB.Model{provider: :custom, id: "my-model", provider_model_id: "my-model"}} =
               ReqLLM.model(%{id: "my-model", provider: :custom})
    end

    test "creates model from map with string keys" do
      assert {:ok, %LLMDB.Model{provider: :acme, id: "acme-chat"}} =
               ReqLLM.model(%{"id" => "acme-chat", "provider" => :acme})
    end

    test "creates model from map with provider string" do
      assert {:ok, %LLMDB.Model{provider: :openai, id: "gpt-4o"}} =
               ReqLLM.model(%{"id" => "gpt-4o", "provider" => "openai"})
    end

    test "enriches inline models with derived fields" do
      assert {:ok,
              %LLMDB.Model{
                provider: :openai,
                id: "gpt-5.3-codex",
                provider_model_id: "gpt-5.3-codex",
                family: "gpt-5.3"
              }} =
               ReqLLM.model(%{id: "gpt-5.3-codex", provider: :openai})
    end

    test "enriches existing LLMDB.Model structs before returning them" do
      model = LLMDB.Model.new!(%{id: "gpt-5.3-codex", provider: :openai})

      assert {:ok,
              %LLMDB.Model{
                provider: :openai,
                id: "gpt-5.3-codex",
                provider_model_id: "gpt-5.3-codex",
                family: "gpt-5.3"
              }} = ReqLLM.model(model)
    end

    test "returns error for map missing required fields" do
      assert {:error, error} = ReqLLM.model(%{id: "no-provider"})
      assert Exception.message(error) =~ "Inline model specs require :provider"
    end

    test "returns error for unknown provider strings" do
      assert {:error, error} = ReqLLM.model(%{provider: "not_registered", id: "my-model"})
      assert Exception.message(error) =~ "existing provider atom or registered provider string"
    end
  end

  describe "model!/1" do
    test "returns a normalized model struct" do
      assert %LLMDB.Model{provider: :openai, id: "gpt-4o"} =
               ReqLLM.model!(%{provider: :openai, id: "gpt-4o"})
    end

    test "raises on invalid inline model specs" do
      assert_raise ReqLLM.Error.Validation.Error, ~r/Inline model specs require :provider/, fn ->
        ReqLLM.model!(%{id: "missing-provider"})
      end
    end
  end

  describe "provider/1 top-level API" do
    test "returns provider module for valid provider" do
      assert {:ok, ReqLLM.Providers.Groq} = ReqLLM.provider(:groq)
    end

    test "returns error for invalid provider" do
      assert {:error, %ReqLLM.Error.Invalid.Provider{provider: :nonexistent}} =
               ReqLLM.provider(:nonexistent)
    end
  end

  defp component_rate(pricing, id) do
    pricing
    |> pricing_components()
    |> Enum.find_value(fn component ->
      if component_id(component) == id do
        Map.get(component, :rate) || Map.get(component, "rate")
      end
    end)
  end

  defp pricing_components(pricing) do
    Map.get(pricing, :components) || Map.get(pricing, "components") || []
  end

  defp component_id(component) do
    Map.get(component, :id) || Map.get(component, "id")
  end
end
