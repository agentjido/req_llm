defmodule ReqLLM.Providers.CheaperInferenceTest do
  @moduledoc """
  Provider-level tests for Cheaper Inference.

  Cheaper Inference uses an OpenAI-compatible chat completions API, so these tests focus on
  provider configuration, request wiring, and shared OpenAI-format encoding/decoding
  without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.CheaperInference

  alias ReqLLM.Providers.CheaperInference

  defp cheaperinference_model(model_id \\ "gpt-5.4-mini", opts \\ []) do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      name: Keyword.get(opts, :name, "Cheaper Inference Test Model"),
      provider: :cheaperinference,
      family: Keyword.get(opts, :family, "test"),
      capabilities: Keyword.get(opts, :capabilities, %{chat: true, tools: %{enabled: true}}),
      limits: Keyword.get(opts, :limits, %{context: 32_768, output: 4096}),
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert CheaperInference.provider_id() == :cheaperinference
      assert CheaperInference.base_url() == "https://api.cheaperinference.com/v1"
      assert CheaperInference.default_env_key() == "CHEAPERINFERENCE_API_KEY"
    end

    test "provider schema is empty (pure OpenAI-compatible)" do
      schema_keys = CheaperInference.provider_schema().schema |> Keyword.keys()
      assert schema_keys == []
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = CheaperInference.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end
    end
  end

  describe "model fallback" do
    test "resolves Cheaper Inference model strings before LLMDB catalog support" do
      assert {:ok, model} = ReqLLM.model("cheaperinference:gpt-5.4-mini")
      assert model.provider == :cheaperinference
      assert model.id == "gpt-5.4-mini"
      assert model.model == "gpt-5.4-mini"
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      model = cheaperinference_model()

      {:ok, request} =
        CheaperInference.prepare_request(:chat, model, "Hello world", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.cheaperinference.com/v1"
    end

    test "prepare_request for :object creates a tool-based chat request" do
      model = cheaperinference_model()
      {:ok, schema} = ReqLLM.Schema.compile(answer: [type: :string, required: true])

      {:ok, request} =
        CheaperInference.prepare_request(:object, model, "Return an answer",
          compiled_schema: schema
        )

      assert request.url.path == "/chat/completions"
      assert request.options[:operation] == :object
      assert [%ReqLLM.Tool{name: "structured_output"}] = request.options[:tools]
    end

    test "prepare_request rejects every unsupported operation with an accurate error" do
      model = cheaperinference_model()
      context = context_fixture()

      for operation <- [
            :embedding,
            :image,
            :speech,
            :transcription,
            :rerank,
            :ocr,
            :video,
            :compact,
            :evaluate,
            :unsupported
          ] do
        assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
                 CheaperInference.prepare_request(operation, model, context, [])

        assert error.parameter =~ "operation: #{inspect(operation)} not supported"
        assert error.parameter =~ "Supported operations: [:chat, :object]"
      end
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      attached =
        CheaperInference.attach(Req.new(), cheaperinference_model(), api_key: "test-api-key")

      assert attached.headers["authorization"] == ["Bearer test-api-key"]
    end

    test "attach adds pipeline steps" do
      attached = CheaperInference.attach(Req.new(), cheaperinference_model(), [])

      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
    end
  end

  describe "base_url configuration" do
    test "respects base_url option override" do
      model = cheaperinference_model()
      custom_url = "https://proxy.example.com/v1"

      {:ok, request} =
        CheaperInference.prepare_request(:chat, model, "Hello", base_url: custom_url)

      assert request.options[:base_url] == custom_url
    end
  end

  describe "body encoding" do
    test "encode_body produces valid OpenAI-compatible JSON" do
      model = cheaperinference_model()

      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: model.model,
          stream: false,
          temperature: 0.7
        ]
      }

      encoded_request = CheaperInference.encode_body(request)

      assert is_binary(IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(encoded_request)))
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["model"] == "gpt-5.4-mini"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
      assert decoded["temperature"] == 0.7
    end
  end

  describe "response decoding" do
    test "decode_response parses OpenAI-format response" do
      mock_resp = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "gpt-5.4-mini",
            content: "Hello from Cheaper Inference!"
          )
      }

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "gpt-5.4-mini",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = CheaperInference.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert ReqLLM.Response.text(decoded_resp.body) == "Hello from Cheaper Inference!"
    end
  end
end
