defmodule ReqLLM.Providers.VeniceTest do
  @moduledoc """
  Provider-level tests for Venice AI implementation.

  Tests the provider contract, parameter translation, body encoding,
  and Venice-specific extensions without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Venice, async: true

  alias ReqLLM.Providers.Venice

  describe "provider contract" do
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
  end

  describe "request preparation & pipeline wiring" do
    test "rejects unsupported operations" do
      {:ok, model} = ReqLLM.model(%{provider: :venice, id: "venice-uncensored"})
      prompt = "Hello world"

      {:error, error} = Venice.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
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
      {:ok, model} = ReqLLM.model(%{provider: :venice, id: "venice-uncensored"})
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Venice.encode_body(mock_request)
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(updated_request))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["model"] == "venice-uncensored"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "venice_parameters")
    end

    test "encode_body with Venice parameters" do
      {:ok, model} = ReqLLM.model(%{provider: :venice, id: "venice-uncensored"})
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
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(updated_request))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert Map.has_key?(decoded, "venice_parameters")
      venice_params = decoded["venice_parameters"]
      assert venice_params["character_slug"] == "test-char"
      assert venice_params["enable_web_search"] == "on"
    end

    test "encode_body converts atom keys to string keys in venice_parameters" do
      {:ok, model} = ReqLLM.model(%{provider: :venice, id: "venice-uncensored"})
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
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(updated_request))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      venice_params = decoded["venice_parameters"]
      assert venice_params["strip_thinking_response"] == true
      assert venice_params["disable_thinking"] == false
      assert venice_params["include_venice_system_prompt"] == false
    end

    test "encode_body with tools" do
      {:ok, model} = ReqLLM.model("venice:zai-org-glm-4.7")
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
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(updated_request))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
    end

    test "encode_body with both tools and venice_parameters" do
      {:ok, model} = ReqLLM.model("venice:zai-org-glm-4.7")
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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert Map.has_key?(decoded, "venice_parameters")
      assert decoded["venice_parameters"]["enable_web_search"] == "auto"
      assert decoded["venice_parameters"]["enable_web_citations"] == true
    end
  end

  describe "response decoding" do
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

  describe "model availability" do
    test "Venice models are available in LLMDB" do
      models = LLMDB.models(:venice)
      refute Enum.empty?(models)
    end

    test "can load specific Venice models" do
      {:ok, model} = ReqLLM.model(%{provider: :venice, id: "venice-uncensored"})
      assert model.provider == :venice
      assert model.id == "venice-uncensored"

      {:ok, model2} = ReqLLM.model("venice:zai-org-glm-4.7")
      assert model2.provider == :venice
      assert model2.id == "zai-org-glm-4.7"
    end
  end

  describe "context validation" do
  end
end
