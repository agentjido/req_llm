defmodule ReqLLM.Providers.VLLMTest do
  @moduledoc """
  Provider-level tests for vLLM implementation.

  Tests the provider contract and wiring without making live API calls.
  vLLM is OpenAI-compatible so tests focus on configuration and routing.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.VLLM

  alias ReqLLM.Providers.VLLM

  defp vllm_model(model_id \\ "test-model", opts \\ []) do
    %LLMDB.Model{
      id: "vllm:#{model_id}",
      model: model_id,
      name: Keyword.get(opts, :name, "vLLM Test Model"),
      provider: :vllm,
      family: Keyword.get(opts, :family, "test"),
      capabilities: Keyword.get(opts, :capabilities, %{chat: true, tools: %{enabled: true}}),
      limits: Keyword.get(opts, :limits, %{context: 32_768, output: 4096})
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert VLLM.provider_id() == :vllm
      assert is_binary(VLLM.base_url())
      assert VLLM.base_url() == "http://localhost:8000/v1"
    end

    test "provider uses OPENAI_API_KEY by default" do
      assert VLLM.default_env_key() == "OPENAI_API_KEY"
    end

    test "provider schema is empty (pure OpenAI-compatible)" do
      schema_keys = VLLM.provider_schema().schema |> Keyword.keys()
      assert schema_keys == []
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = VLLM.provider_extended_generation_schema()
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
      model = vllm_model()
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = VLLM.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "prepare_request for :embedding creates /embeddings request" do
      model = vllm_model("embedding-model", capabilities: %{embeddings: true})
      text = "Hello world"
      opts = []

      {:ok, request} = VLLM.prepare_request(:embedding, model, text, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/embeddings"
      assert request.method == :post
    end

    test "prepare_request rejects unsupported operations" do
      model = vllm_model()
      context = context_fixture()

      {:error, error} = VLLM.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      model = vllm_model()
      request = Req.new()

      attached = VLLM.attach(request, model, [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")
    end

    test "attach adds pipeline steps" do
      model = vllm_model()
      request = Req.new()

      attached = VLLM.attach(request, model, [])

      request_steps = Keyword.keys(attached.request_steps)
      response_steps = Keyword.keys(attached.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end
  end

  describe "base_url configuration" do
    test "uses default base_url when not overridden" do
      model = vllm_model()
      {:ok, request} = VLLM.prepare_request(:chat, model, "Hello", [])

      assert request.options[:base_url] == "http://localhost:8000/v1"
    end

    test "respects base_url option override" do
      model = vllm_model()
      custom_url = "http://my-vllm-server:8001/v1"
      {:ok, request} = VLLM.prepare_request(:chat, model, "Hello", base_url: custom_url)

      assert request.options[:base_url] == custom_url
    end
  end

  describe "body encoding" do
    test "encode_body produces valid OpenAI-compatible JSON" do
      model = vllm_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          temperature: 0.7
        ]
      }

      updated_request = VLLM.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "test-model"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
    end

    test "encode_body handles tools correctly" do
      model = vllm_model()
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [
            location: [type: :string, required: true, doc: "City name"]
          ],
          callback: fn _ -> {:ok, "sunny"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool]
        ]
      }

      updated_request = VLLM.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      assert hd(decoded["tools"])["function"]["name"] == "get_weather"
    end
  end

  describe "response decoding" do
    test "decode_response parses OpenAI-format response" do
      mock_response_body =
        openai_format_json_fixture(
          model: "test-model",
          content: "Hello from vLLM!"
        )

      mock_resp = %Req.Response{
        status: 200,
        body: mock_response_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [
          context: context,
          model: "test-model",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = VLLM.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert ReqLLM.Response.text(decoded_resp.body) == "Hello from vLLM!"
    end
  end
end
