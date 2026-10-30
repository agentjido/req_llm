defmodule ReqLLM.Providers.NearAITest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.NearAI, async: true

  import ExUnit.CaptureIO

  alias ReqLLM.Providers.NearAI

  defp nearai_model(model_id \\ "anthropic/claude-haiku-4-5") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :nearai,
      name: model_id,
      family: "nearai-openai-compatible",
      capabilities: %{chat: true, tools: %{enabled: true}},
      limits: %{context: 128_000, output: 4096},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  describe "provider contract" do
    test "provider schema exposes NEAR compatibility options" do
      schema_keys = NearAI.provider_schema().schema |> Keyword.keys()

      assert :max_completion_tokens in schema_keys
    end
  end

  describe "model fallback" do
    test "resolves NEAR model strings before LLMDB catalog support" do
      capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("nearai:anthropic/claude-haiku-4-5")
        assert model.provider == :nearai
        assert model.id == "anthropic/claude-haiku-4-5"
      end)
    end
  end

  describe "option translation and body encoding" do
    test "translate_options maps max_completion_tokens and removes unsupported reasoning options" do
      {translated, warnings} =
        NearAI.translate_options(
          :chat,
          nearai_model(),
          max_completion_tokens: 256,
          reasoning_effort: :high,
          reasoning_token_budget: 1000
        )

      assert translated[:max_tokens] == 256
      refute Keyword.has_key?(translated, :max_completion_tokens)
      refute Keyword.has_key?(translated, :reasoning_effort)
      refute Keyword.has_key?(translated, :reasoning_token_budget)
      assert length(warnings) == 3
    end

    test "translate_options preserves explicit max_tokens over max_completion_tokens" do
      {translated, warnings} =
        NearAI.translate_options(
          :chat,
          nearai_model(),
          max_tokens: 128,
          max_completion_tokens: 256
        )

      assert translated[:max_tokens] == 128
      refute Keyword.has_key?(translated, :max_completion_tokens)
      assert [warning] = warnings
      assert warning =~ "ignored max_completion_tokens"
    end

    test "encode_body emits NEAR-compatible chat body" do
      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "anthropic/claude-haiku-4-5",
          stream: false,
          max_completion_tokens: 512,
          reasoning_effort: :high
        ]
      }

      encoded_request = NearAI.encode_body(request)
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(encoded_request))
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["model"] == "anthropic/claude-haiku-4-5"
      assert decoded["max_tokens"] == 512
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "max_completion_tokens")
      refute Map.has_key?(decoded, "reasoning_effort")
      assert is_list(decoded["messages"])
    end

    test "encode_body strips strict markers from tools" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [
            location: [type: :string, required: true, doc: "City name"]
          ],
          callback: fn _ -> {:ok, "sunny"} end,
          strict: true
        )

      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "anthropic/claude-haiku-4-5",
          stream: false,
          tools: [tool]
        ]
      }

      encoded_request = NearAI.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)
      function = decoded["tools"] |> hd() |> Map.fetch!("function")

      assert function["name"] == "get_weather"
      refute Map.has_key?(function, "strict")
    end
  end
end
