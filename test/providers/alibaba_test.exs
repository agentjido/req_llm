defmodule ReqLLM.Providers.AlibabaTest do
  @moduledoc """
  Provider-level tests for Alibaba Cloud Bailian (DashScope) international implementation.

  Tests the provider contract, parameter translation, body encoding,
  and DashScope-specific extensions without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Alibaba

  alias ReqLLM.Context
  alias ReqLLM.Providers.Alibaba

  # LLMDB doesn't have alibaba models yet, so we create them manually
  defp model_fixture do
    {:ok, model} = ReqLLM.model(%{provider: :alibaba, id: "qwen-plus"})
    model
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Alibaba.provider_id())
      assert Alibaba.provider_id() == :alibaba
      assert is_binary(Alibaba.base_url())
      assert Alibaba.base_url() == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
    end

    test "provider uses correct default environment key" do
      assert Alibaba.default_env_key() == "DASHSCOPE_API_KEY"
    end

    test "provider schema separation from core options" do
      schema_keys = Alibaba.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema includes DashScope-specific options" do
      schema_keys = Alibaba.provider_schema().schema |> Keyword.keys()

      expected_keys = [
        :enable_search,
        :search_options,
        :enable_thinking,
        :thinking_budget,
        :repetition_penalty,
        :enable_code_interpreter,
        :vl_high_resolution_images,
        :incremental_output
      ]

      for key <- expected_keys do
        assert key in schema_keys, "Expected #{key} in provider schema"
      end
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = Alibaba.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = Alibaba.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      provider_keys = Alibaba.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request for :chat" do
      model = model_fixture()
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Alibaba.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      model = model_fixture()
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Alibaba.attach(model, opts)

      auth_header = Enum.find(request.headers, fn {name, _} -> name == "authorization" end)
      assert auth_header != nil
      {_, [auth_value]} = auth_header
      assert String.starts_with?(auth_value, "Bearer ")

      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "prepare_request preserves DashScope provider options for encoding" do
      model = model_fixture()

      {:ok, request} =
        Alibaba.prepare_request(:chat, model, "Hello world",
          provider_options: [enable_search: true, enable_thinking: true]
        )

      assert request.options[:dashscope_parameters] == %{
               enable_search: true,
               enable_thinking: true
             }

      encoded_request = Alibaba.encode_body(request)
      decoded = Jason.decode!(encoded_request.body)

      assert decoded["enable_search"] == true
      assert decoded["enable_thinking"] == true
    end

    test "rejects unsupported operations" do
      model = model_fixture()
      prompt = "Hello world"

      {:error, error} = Alibaba.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end

    test "rejects provider mismatch" do
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Alibaba.attach(wrong_model, [])
      end
    end
  end

  describe "translate_options/3" do
    test "extracts DashScope-specific options into dashscope_parameters" do
      opts = [
        enable_search: true,
        enable_thinking: true,
        temperature: 0.7
      ]

      {translated, warnings} = Alibaba.translate_options(:chat, nil, opts)

      assert warnings == []

      assert translated[:dashscope_parameters] == %{
               enable_search: true,
               enable_thinking: true
             }

      assert translated[:temperature] == 0.7
      refute Keyword.has_key?(translated, :enable_search)
      refute Keyword.has_key?(translated, :enable_thinking)
    end

    test "handles all DashScope-specific options" do
      opts = [
        enable_search: true,
        search_options: %{search_strategy: "agent", enable_source: true},
        enable_thinking: true,
        thinking_budget: 4096,
        repetition_penalty: 1.1,
        enable_code_interpreter: true,
        vl_high_resolution_images: true,
        incremental_output: true
      ]

      {translated, warnings} = Alibaba.translate_options(:chat, nil, opts)

      assert warnings == []
      dashscope_params = translated[:dashscope_parameters]
      assert dashscope_params[:enable_search] == true
      assert dashscope_params[:search_options] == %{search_strategy: "agent", enable_source: true}
      assert dashscope_params[:enable_thinking] == true
      assert dashscope_params[:thinking_budget] == 4096
      assert dashscope_params[:repetition_penalty] == 1.1
      assert dashscope_params[:enable_code_interpreter] == true
      assert dashscope_params[:vl_high_resolution_images] == true
      assert dashscope_params[:incremental_output] == true
    end

    test "passes through non-DashScope options unchanged" do
      opts = [
        temperature: 0.7,
        max_tokens: 100,
        top_p: 0.9,
        seed: 42
      ]

      {translated, warnings} = Alibaba.translate_options(:chat, nil, opts)

      assert warnings == []
      assert translated[:temperature] == 0.7
      assert translated[:max_tokens] == 100
      assert translated[:top_p] == 0.9
      assert translated[:seed] == 42
      refute Keyword.has_key?(translated, :dashscope_parameters)
    end

    test "filters out nil DashScope option values" do
      opts = [
        enable_search: nil,
        enable_thinking: true,
        temperature: 0.5
      ]

      {translated, _warnings} = Alibaba.translate_options(:chat, nil, opts)

      dashscope_params = translated[:dashscope_parameters]
      refute Map.has_key?(dashscope_params, :enable_search)
      assert dashscope_params[:enable_thinking] == true
    end

    test "returns no dashscope_parameters when no DashScope options provided" do
      opts = [temperature: 0.7, max_tokens: 100]

      {translated, warnings} = Alibaba.translate_options(:chat, nil, opts)

      assert warnings == []
      refute Keyword.has_key?(translated, :dashscope_parameters)
      assert translated[:temperature] == 0.7
      assert translated[:max_tokens] == 100
    end
  end

  describe "body encoding" do
    test "encode_body with minimal context" do
      model = model_fixture()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "qwen-plus"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "enable_search")
      refute Map.has_key?(decoded, "enable_thinking")
    end

    test "encode_body with search parameters" do
      model = model_fixture()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          dashscope_parameters: %{
            enable_search: true,
            search_options: %{search_strategy: "agent", enable_source: true}
          }
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["enable_search"] == true
      assert Map.has_key?(decoded, "search_options")
      search_opts = decoded["search_options"]
      assert search_opts["search_strategy"] == "agent"
      assert search_opts["enable_source"] == true
    end

    test "encode_body with thinking parameters" do
      model = model_fixture()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          dashscope_parameters: %{
            enable_thinking: true,
            thinking_budget: 4096
          }
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["enable_thinking"] == true
      assert decoded["thinking_budget"] == 4096
    end

    test "encode_body with top_k sampling" do
      model = model_fixture()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          top_k: 50
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["top_k"] == 50
    end

    test "encode_body with tools" do
      model = model_fixture()
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool]
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      assert_no_duplicate_json_keys(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
    end

    test "encode_body with tools and DashScope parameters" do
      model = model_fixture()
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "search_tool",
          description: "Search the web",
          parameter_schema: [query: [type: :string, required: true]],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          dashscope_parameters: %{
            enable_search: true,
            repetition_penalty: 1.1
          }
        ]
      }

      updated_request = Alibaba.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert decoded["enable_search"] == true
      assert decoded["repetition_penalty"] == 1.1
    end
  end

  describe "streaming request encoding" do
    test "attach_stream translates DashScope options before encoding" do
      model = model_fixture()
      context = context_fixture()

      {:ok, request} =
        Alibaba.attach_stream(
          model,
          context,
          [
            enable_search: true,
            enable_thinking: true,
            incremental_output: true,
            top_k: 50
          ],
          ReqLLM.Finch
        )

      decoded = Jason.decode!(request.body)

      assert decoded["enable_search"] == true
      assert decoded["enable_thinking"] == true
      assert decoded["incremental_output"] == true
      assert decoded["top_k"] == 50
      assert decoded["stream"] == true
    end

    test "attach_stream honors nested provider_options" do
      model = model_fixture()
      context = context_fixture()

      {:ok, request} =
        Alibaba.attach_stream(
          model,
          context,
          [
            provider_options: [
              enable_search: true,
              enable_thinking: true,
              incremental_output: true
            ],
            top_k: 50
          ],
          ReqLLM.Finch
        )

      decoded = Jason.decode!(request.body)

      assert decoded["enable_search"] == true
      assert decoded["enable_thinking"] == true
      assert decoded["incremental_output"] == true
      assert decoded["top_k"] == 50
      assert decoded["stream"] == true
    end
  end

  describe "response decoding" do
    test "decode_response handles successful non-streaming response" do
      mock_json_response =
        openai_format_json_fixture(
          model: "qwen-plus",
          content: "Hello! I'm Qwen."
        )

      mock_resp = %Req.Response{
        status: 200,
        body: mock_json_response
      }

      model = model_fixture()
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "alibaba:qwen-plus"],
        private: %{req_llm_model: model}
      }

      {req, resp} = Alibaba.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.stream? == false

      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert is_binary(text)
      assert String.length(text) > 0

      assert is_integer(response.usage.input_tokens)
      assert is_integer(response.usage.output_tokens)
    end

    test "decode_response handles streaming responses" do
      mock_resp = %Req.Response{
        status: 200,
        body: []
      }

      context = context_fixture()
      model_id = "qwen-plus"
      mock_stream = ["Hello", " world", "!"]

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model_id],
        private: %{real_time_stream: mock_stream}
      }

      {req, resp} = Alibaba.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert response.stream == mock_stream
      assert response.model == model_id
    end

    test "decode_response handles API errors" do
      error_body = %{
        "error" => %{
          "message" => "Invalid API key",
          "type" => "authentication_error"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "qwen-plus"]
      }

      {req, error} = Alibaba.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      model = model_fixture()

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 15,
          "completion_tokens" => 25,
          "total_tokens" => 40
        }
      }

      {:ok, usage} = Alibaba.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 15
      assert usage["completion_tokens"] == 25
      assert usage["total_tokens"] == 40
    end

    test "extract_usage with missing usage data" do
      model = model_fixture()
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = Alibaba.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      model = model_fixture()

      {:error, :invalid_body} = Alibaba.extract_usage("invalid", model)
      {:error, :invalid_body} = Alibaba.extract_usage(nil, model)
    end
  end

  describe "context validation" do
    test "multiple system messages should fail" do
      invalid_context =
        Context.new([
          Context.system("System 1"),
          Context.system("System 2"),
          Context.user("Hello")
        ])

      assert_raise ReqLLM.Error.Validation.Error,
                   ~r/should have at most one system message/,
                   fn ->
                     Context.validate!(invalid_context)
                   end
    end
  end
end
