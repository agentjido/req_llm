defmodule ReqLLMTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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

    test "normalizes gpt-4o model wire protocol to openai_responses when metadata lags" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")

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

    test "resolves unknown registered provider string specs with a warning" do
      output =
        capture_io(:stderr, fn ->
          assert {:ok,
                  %LLMDB.Model{
                    provider: :openai,
                    id: "brand-new-model",
                    provider_model_id: "brand-new-model"
                  }} = ReqLLM.model("openai:brand-new-model")
        end)

      assert output =~ "Using unverified model: openai:brand-new-model"
      assert output =~ "To suppress this warning, use an inline model spec"
    end

    test "resolves unknown registered provider tuple specs with a warning" do
      output =
        capture_io(:stderr, fn ->
          assert {:ok,
                  %LLMDB.Model{
                    provider: :openai,
                    id: "tuple-fallback-model",
                    provider_model_id: "tuple-fallback-model"
                  }} = ReqLLM.model({:openai, id: "tuple-fallback-model"})
        end)

      assert output =~ "Using unverified model: openai:tuple-fallback-model"
    end

    test "resolves cohere string specs via inline model fallback" do
      output =
        capture_io(:stderr, fn ->
          assert {:ok,
                  %LLMDB.Model{
                    provider: :cohere,
                    id: "rerank-v3.5",
                    provider_model_id: "rerank-v3.5"
                  }} = ReqLLM.model("cohere:rerank-v3.5")
        end)

      assert output =~ "Using unverified model: cohere:rerank-v3.5"
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

    test "does not warn for explicit inline model specs" do
      output =
        capture_io(:stderr, fn ->
          assert {:ok, %LLMDB.Model{provider: :openai, id: "quiet-inline-model"}} =
                   ReqLLM.model(%{id: "quiet-inline-model", provider: :openai})
        end)

      assert output == ""
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

  describe "model/1 google pricing normalization" do
    test "adds long-context pricing tiers for google pro preview models" do
      {:ok, model} = ReqLLM.model("google:gemini-3.1-pro-preview")

      assert pricing_component(model, "token.input.standard_context").rate == 2.0
      assert pricing_component(model, "token.input.standard_context").max_input_tokens == 200_000
      assert pricing_component(model, "token.input.long_context").rate == 4.0
      assert pricing_component(model, "token.input.long_context").min_input_tokens == 200_001
      assert pricing_component(model, "token.output.standard_context").rate == 12.0
      assert pricing_component(model, "token.output.long_context").rate == 18.0
      assert pricing_component(model, "token.cache_read.standard_context").rate == 0.2
      assert pricing_component(model, "token.cache_read.long_context").rate == 0.4
      refute pricing_component(model, "token.input")
    end

    test "backfills missing token pricing for google computer use preview models" do
      {:ok, model} = ReqLLM.model("google:gemini-2.5-computer-use-preview-10-2025")

      assert model.cost == %{input: 1.25, output: 10.0}
      assert pricing_component(model, "token.input.standard_context").rate == 1.25
      assert pricing_component(model, "token.input.long_context").rate == 2.5
      assert pricing_component(model, "token.output.standard_context").rate == 10.0
      assert pricing_component(model, "token.output.long_context").rate == 15.0
      refute pricing_component(model, "token.cache_read.standard_context")
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

  defp pricing_component(model, id) do
    model.pricing.components
    |> Enum.find(fn component -> component.id == id end)
  end
end
