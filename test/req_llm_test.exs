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
end
