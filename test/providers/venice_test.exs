defmodule ReqLLM.Providers.VeniceTest do
  @moduledoc """
  Provider-level tests for Venice AI implementation.

  Tests the provider contract, parameter translation, body encoding,
  and Venice-specific extensions without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Venice

  alias ReqLLM.Context
  alias ReqLLM.Providers.Venice

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Venice.provider_id())
      assert Venice.provider_id() == :venice
      assert is_binary(Venice.base_url())
      assert Venice.base_url() == "https://api.venice.ai/api/v1"
    end

    test "provider uses correct default environment key" do
      assert Venice.default_env_key() == "VENICE_API_KEY"
    end

    test "provider schema separation from core options" do
      schema_keys = Venice.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema includes Venice-specific options" do
      schema_keys = Venice.provider_schema().schema |> Keyword.keys()

      expected_venice_keys = [
        :character_slug,
        :strip_thinking_response,
        :disable_thinking,
        :enable_web_search,
        :enable_web_scraping,
        :enable_web_citations,
        :include_search_results_in_stream,
        :return_search_results_as_documents,
        :include_venice_system_prompt
      ]

      for key <- expected_venice_keys do
        assert key in schema_keys, "Expected #{key} in provider schema"
      end
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = Venice.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = Venice.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      provider_keys = Venice.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request for :chat" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Venice.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Venice.attach(model, opts)

      auth_header = Enum.find(request.headers, fn {name, _} -> name == "authorization" end)
      assert auth_header != nil
      {_, [auth_value]} = auth_header
      assert String.starts_with?(auth_value, "Bearer ")

      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "rejects unsupported operations" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      prompt = "Hello world"

      {:error, error} = Venice.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end

    test "rejects provider mismatch" do
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Venice.attach(wrong_model, [])
      end
    end
  end

  describe "translate_options/3" do
    test "extracts Venice-specific options into venice_parameters" do
      opts = [
        character_slug: "test-char",
        enable_web_search: "on",
        temperature: 0.7
      ]

      {translated, warnings} = Venice.translate_options(:chat, nil, opts)

      assert warnings == []

      assert translated[:venice_parameters] == %{
               character_slug: "test-char",
               enable_web_search: "on"
             }

      assert translated[:temperature] == 0.7
      refute Keyword.has_key?(translated, :character_slug)
      refute Keyword.has_key?(translated, :enable_web_search)
    end

    test "handles all Venice-specific options" do
      opts = [
        character_slug: "my-char",
        strip_thinking_response: true,
        disable_thinking: false,
        enable_web_search: "auto",
        enable_web_scraping: true,
        enable_web_citations: true,
        include_search_results_in_stream: true,
        return_search_results_as_documents: true,
        include_venice_system_prompt: false
      ]

      {translated, warnings} = Venice.translate_options(:chat, nil, opts)

      assert warnings == []
      venice_params = translated[:venice_parameters]
      assert venice_params[:character_slug] == "my-char"
      assert venice_params[:strip_thinking_response] == true
      assert venice_params[:disable_thinking] == false
      assert venice_params[:enable_web_search] == "auto"
      assert venice_params[:enable_web_scraping] == true
      assert venice_params[:enable_web_citations] == true
      assert venice_params[:include_search_results_in_stream] == true
      assert venice_params[:return_search_results_as_documents] == true
      assert venice_params[:include_venice_system_prompt] == false
    end

    test "passes through non-Venice options unchanged" do
      opts = [
        temperature: 0.7,
        max_tokens: 100,
        top_p: 0.9,
        seed: 42
      ]

      {translated, warnings} = Venice.translate_options(:chat, nil, opts)

      assert warnings == []
      assert translated[:temperature] == 0.7
      assert translated[:max_tokens] == 100
      assert translated[:top_p] == 0.9
      assert translated[:seed] == 42
      refute Keyword.has_key?(translated, :venice_parameters)
    end

    test "filters out nil Venice option values" do
      opts = [
        character_slug: nil,
        enable_web_search: "on",
        temperature: 0.5
      ]

      {translated, _warnings} = Venice.translate_options(:chat, nil, opts)

      venice_params = translated[:venice_parameters]
      refute Map.has_key?(venice_params, :character_slug)
      assert venice_params[:enable_web_search] == "on"
    end

    test "returns empty venice_parameters when no Venice options provided" do
      opts = [temperature: 0.7, max_tokens: 100]

      {translated, warnings} = Venice.translate_options(:chat, nil, opts)

      assert warnings == []
      refute Keyword.has_key?(translated, :venice_parameters)
      assert translated[:temperature] == 0.7
      assert translated[:max_tokens] == 100
    end
  end

  describe "body encoding" do
    test "encode_body with minimal context" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Venice.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "venice-uncensored"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "venice_parameters")
    end

    test "encode_body with Venice parameters" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          venice_parameters: %{
            character_slug: "test-char",
            enable_web_search: "on"
          }
        ]
      }

      updated_request = Venice.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert Map.has_key?(decoded, "venice_parameters")
      venice_params = decoded["venice_parameters"]
      assert venice_params["character_slug"] == "test-char"
      assert venice_params["enable_web_search"] == "on"
    end

    test "encode_body converts atom keys to string keys in venice_parameters" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          venice_parameters: %{
            strip_thinking_response: true,
            disable_thinking: false,
            include_venice_system_prompt: false
          }
        ]
      }

      updated_request = Venice.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      venice_params = decoded["venice_parameters"]
      assert venice_params["strip_thinking_response"] == true
      assert venice_params["disable_thinking"] == false
      assert venice_params["include_venice_system_prompt"] == false
    end

    test "encode_body with tools" do
      {:ok, model} = ReqLLM.model("venice:zai-org-glm-4.6")
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

      updated_request = Venice.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
    end

    test "encode_body with both tools and venice_parameters" do
      {:ok, model} = ReqLLM.model("venice:zai-org-glm-4.6")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "web_search_tool",
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
          venice_parameters: %{
            enable_web_search: "auto",
            enable_web_citations: true
          }
        ]
      }

      updated_request = Venice.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert Map.has_key?(decoded, "venice_parameters")
      assert decoded["venice_parameters"]["enable_web_search"] == "auto"
      assert decoded["venice_parameters"]["enable_web_citations"] == true
    end
  end

  describe "response decoding" do
    test "decode_response handles successful non-streaming response" do
      mock_json_response =
        openai_format_json_fixture(
          model: "venice-uncensored",
          content: "Hello! I'm doing well."
        )

      mock_resp = %Req.Response{
        status: 200,
        body: mock_json_response
      }

      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "venice:venice-uncensored"],
        private: %{req_llm_model: model}
      }

      {req, resp} = Venice.decode_response({mock_req, mock_resp})

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
      model = "venice-uncensored"
      mock_stream = ["Hello", " world", "!"]

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model],
        private: %{real_time_stream: mock_stream}
      }

      {req, resp} = Venice.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert response.stream == mock_stream
      assert response.model == model
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
        options: [context: context, id: "venice-uncensored"]
      }

      {req, error} = Venice.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 15,
          "completion_tokens" => 25,
          "total_tokens" => 40
        }
      }

      {:ok, usage} = Venice.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 15
      assert usage["completion_tokens"] == 25
      assert usage["total_tokens"] == 40
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = Venice.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")

      {:error, :invalid_body} = Venice.extract_usage("invalid", model)
      {:error, :invalid_body} = Venice.extract_usage(nil, model)
    end
  end

  describe "model availability" do
    test "Venice models are available in LLMDB" do
      models = LLMDB.models(:venice)
      refute Enum.empty?(models)
    end

    test "can load specific Venice models" do
      {:ok, model} = ReqLLM.model("venice:venice-uncensored")
      assert model.provider == :venice
      assert model.id == "venice-uncensored"

      {:ok, model2} = ReqLLM.model("venice:zai-org-glm-4.6")
      assert model2.provider == :venice
      assert model2.id == "zai-org-glm-4.6"
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
