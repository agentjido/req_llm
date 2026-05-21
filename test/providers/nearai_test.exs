defmodule ReqLLM.Providers.NearAITest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.NearAI

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
    test "provider identity and configuration" do
      assert NearAI.provider_id() == :nearai
      assert NearAI.base_url() == "https://cloud-api.near.ai/v1"
      assert NearAI.default_env_key() == "NEARAI_API_KEY"
      assert NearAI.display_name() == "NEAR AI Cloud"
    end

    test "provider schema exposes NEAR compatibility options" do
      schema_keys = NearAI.provider_schema().schema |> Keyword.keys()

      assert :max_completion_tokens in schema_keys
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = NearAI.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys
      end
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

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      {:ok, request} =
        NearAI.prepare_request(:chat, nearai_model(), "Hello world", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:base_url] == "https://cloud-api.near.ai/v1"
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header and pipeline steps" do
      attached = NearAI.attach(Req.new(), nearai_model(), [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")

      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
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
      assert_no_duplicate_json_keys(encoded_request.body)
      decoded = Jason.decode!(encoded_request.body)

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
      decoded = Jason.decode!(encoded_request.body)
      function = decoded["tools"] |> hd() |> Map.fetch!("function")

      assert function["name"] == "get_weather"
      refute Map.has_key?(function, "strict")
    end
  end

  describe "response decoding" do
    test "decode_response handles successful OpenAI-compatible responses" do
      mock_resp = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "anthropic/claude-haiku-4-5",
            content: "Hello from NEAR AI Cloud."
          )
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "nearai:anthropic/claude-haiku-4-5"],
        private: %{req_llm_model: nearai_model()}
      }

      {req, resp} = NearAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body
      assert ReqLLM.Response.text(resp.body) == "Hello from NEAR AI Cloud."
      assert resp.body.usage.input_tokens == 10
      assert resp.body.usage.output_tokens == 8
    end
  end
end
