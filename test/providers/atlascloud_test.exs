defmodule ReqLLM.Providers.AtlasCloudTest do
  @moduledoc """
  Provider-level tests for Atlas Cloud.

  Atlas Cloud uses an OpenAI-compatible chat completions API, so these tests focus on
  provider configuration, request wiring, and shared OpenAI-format encoding/decoding
  without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.AtlasCloud

  alias ReqLLM.Providers.AtlasCloud

  defp atlascloud_model(model_id \\ "qwen/qwen3.5-flash", opts \\ []) do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      name: Keyword.get(opts, :name, "Atlas Cloud Test Model"),
      provider: :atlascloud,
      family: Keyword.get(opts, :family, "test"),
      capabilities: Keyword.get(opts, :capabilities, %{chat: true, tools: %{enabled: true}}),
      limits: Keyword.get(opts, :limits, %{context: 32_768, output: 4096}),
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert AtlasCloud.provider_id() == :atlascloud
      assert AtlasCloud.base_url() == "https://api.atlascloud.ai/v1"
      assert AtlasCloud.default_env_key() == "ATLASCLOUD_API_KEY"
    end

    test "provider schema is empty (pure OpenAI-compatible)" do
      schema_keys = AtlasCloud.provider_schema().schema |> Keyword.keys()
      assert schema_keys == []
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = AtlasCloud.provider_extended_generation_schema()
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
    test "resolves Atlas Cloud model strings before LLMDB catalog support" do
      assert {:ok, model} = ReqLLM.model("atlascloud:qwen/qwen3.5-flash")
      assert model.provider == :atlascloud
      assert model.id == "qwen/qwen3.5-flash"
      assert model.model == "qwen/qwen3.5-flash"
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      model = atlascloud_model()

      {:ok, request} = AtlasCloud.prepare_request(:chat, model, "Hello world", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.atlascloud.ai/v1"
    end

    test "prepare_request rejects non-chat operations Atlas Cloud does not expose here" do
      model = atlascloud_model()

      {:error, error} = AtlasCloud.prepare_request(:embedding, model, "Hello", [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end

    test "prepare_request rejects unsupported operations" do
      model = atlascloud_model()
      context = context_fixture()

      {:error, error} = AtlasCloud.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      attached = AtlasCloud.attach(Req.new(), atlascloud_model(), [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")
    end

    test "attach adds pipeline steps" do
      attached = AtlasCloud.attach(Req.new(), atlascloud_model(), [])

      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
    end
  end

  describe "base_url configuration" do
    test "respects base_url option override" do
      model = atlascloud_model()
      custom_url = "https://proxy.example.com/v1"

      {:ok, request} = AtlasCloud.prepare_request(:chat, model, "Hello", base_url: custom_url)

      assert request.options[:base_url] == custom_url
    end
  end

  describe "body encoding" do
    test "encode_body produces valid OpenAI-compatible JSON" do
      model = atlascloud_model()

      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: model.model,
          stream: false,
          temperature: 0.7
        ]
      }

      encoded_request = AtlasCloud.encode_body(request)

      assert is_binary(IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(encoded_request)))
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["model"] == "qwen/qwen3.5-flash"
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
            model: "qwen/qwen3.5-flash",
            content: "Hello from Atlas Cloud!"
          )
      }

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "qwen/qwen3.5-flash",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = AtlasCloud.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert ReqLLM.Response.text(decoded_resp.body) == "Hello from Atlas Cloud!"
    end
  end
end
