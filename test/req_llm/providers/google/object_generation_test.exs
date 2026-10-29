defmodule ReqLLM.Providers.Google.ObjectGenerationTest do
  @moduledoc """
  Google native JSON mode requests, schemas, and object responses.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Providers.Google

  describe "object generation with native JSON mode" do
    test "prepare_request for :object with low max_tokens gets adjusted" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      opts = [max_tokens: 50, compiled_schema: schema]
      {:ok, request} = Google.prepare_request(:object, model, context, opts)

      assert request.options[:max_tokens] == 200
    end

    test "prepare_request for :object with nil max_tokens gets default" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile([])

      opts = [compiled_schema: schema]
      {:ok, request} = Google.prepare_request(:object, model, context, opts)

      assert request.options[:max_tokens] == model.limits.output
    end

    test "prepare_request for :object with sufficient max_tokens unchanged" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(value: [type: :integer])

      opts = [max_tokens: 1000, compiled_schema: schema]
      {:ok, request} = Google.prepare_request(:object, model, context, opts)

      assert request.options[:max_tokens] == 1000
    end

    test "prepare_request for :object rejects tools" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "ok"} end
        )

      opts = [compiled_schema: schema, tools: [tool]]
      {:error, error} = Google.prepare_request(:object, model, context, opts)

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "tools are not supported"
    end

    test "prepare_request for :object allows tools on Gemini 3" do
      {:ok, model} = ReqLLM.model("google:gemini-3-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "ok"} end
        )

      opts = [compiled_schema: schema, tools: [tool]]
      {:ok, request} = Google.prepare_request(:object, model, context, opts)

      assert request.options[:tools] == [tool]
    end

    test "prepare_request for :object rejects tools on Gemini 2.5" do
      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "ok"} end
        )

      opts = [compiled_schema: schema, tools: [tool]]
      {:error, error} = Google.prepare_request(:object, model, context, opts)

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "tools are not supported"
      assert error.parameter =~ "pre-Gemini-3"
      assert error.parameter =~ "gemini-2.5-flash"
    end

    test "prepare_request for :object allows an empty tools list on Gemini 1.5" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      opts = [compiled_schema: schema, tools: []]
      assert {:ok, _request} = Google.prepare_request(:object, model, context, opts)
    end

    test "prepare_request for :object returns unresolved model errors when tools are present" do
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test",
          parameter_schema: [],
          callback: fn _ -> {:ok, "ok"} end
        )

      model_spec = "google:"
      {:error, model_error} = ReqLLM.model(model_spec)

      {:error, error} =
        Google.prepare_request(:object, model_spec, context,
          compiled_schema: schema,
          tools: [tool]
        )

      assert error == model_error
    end

    test "encode_object_body creates JSON mode request" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          operation: :object,
          compiled_schema: schema,
          max_tokens: 500,
          provider_options: [google_api_version: "v1beta"]
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["generationConfig"]["responseMimeType"] == "application/json"
      assert decoded["generationConfig"]["candidateCount"] == 1
      assert Map.has_key?(decoded["generationConfig"], "responseSchema")
      refute Map.has_key?(decoded, "tools")
      refute Map.has_key?(decoded, "toolConfig")
    end

    test "encode_object_body disables thought summaries when thinking is enabled" do
      {:ok, model} = ReqLLM.model("google:gemini-3-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          operation: :object,
          compiled_schema: schema,
          google_thinking_level: :low,
          provider_options: [google_api_version: "v1beta"]
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      thinking_config = decoded["generationConfig"]["thinkingConfig"]
      assert thinking_config["thinkingLevel"] == "low"
      assert thinking_config["includeThoughts"] == false
    end

    test "encode_object_body uses responseSchema for non-2.5 models" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true],
          age: [type: :pos_integer]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          operation: :object,
          compiled_schema: schema
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      response_schema = decoded["generationConfig"]["responseSchema"]
      assert response_schema["type"] == "OBJECT"
      assert Map.has_key?(response_schema, "properties")
      assert Map.has_key?(response_schema["properties"], "name")
      assert response_schema["properties"]["name"]["type"] == "STRING"
      refute Map.has_key?(decoded["generationConfig"], "responseJsonSchema")
    end

    test "encode_object_body preserves responseSchema propertyOrdering for non-2.5 models" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(
          summary: [type: :string, required: true],
          answer: [type: :string, required: true],
          confidence: [type: :integer]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          operation: :object,
          compiled_schema: schema
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      response_schema = decoded["generationConfig"]["responseSchema"]
      assert response_schema["propertyOrdering"] == ["summary", "answer", "confidence"]
    end

    test "encode_object_body uses responseJsonSchema for Gemini 2.5" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true],
          age: [type: :pos_integer]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-2.5-flash",
          operation: :object,
          compiled_schema: schema
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      response_json_schema = decoded["generationConfig"]["responseJsonSchema"]
      assert response_json_schema["type"] == "object"
      assert Map.has_key?(response_json_schema, "properties")
      refute Map.has_key?(decoded["generationConfig"], "responseSchema")
    end

    test "encode_object_body preserves responseJsonSchema propertyOrdering for Gemini 2.5" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(
          summary: [type: :string, required: true],
          answer: [type: :string, required: true],
          confidence: [type: :integer]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-2.5-flash",
          operation: :object,
          compiled_schema: schema
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      response_json_schema = decoded["generationConfig"]["responseJsonSchema"]
      assert response_json_schema["propertyOrdering"] == ["summary", "answer", "confidence"]
    end

    test "encode_object_body uses responseJsonSchema for Gemini 3.1" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true],
          age: [type: :pos_integer]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-3.1-pro-preview",
          operation: :object,
          compiled_schema: schema
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      response_json_schema = decoded["generationConfig"]["responseJsonSchema"]
      assert response_json_schema["type"] == "object"
      assert Map.has_key?(response_json_schema, "properties")
      refute Map.has_key?(decoded["generationConfig"], "responseSchema")
      refute Map.has_key?(decoded, "tools")
      refute Map.has_key?(decoded, "toolConfig")
    end

    test "encode_object_body includes tools and JSON schema for Gemini 3" do
      context = context_fixture()

      {:ok, schema} =
        ReqLLM.Schema.compile(name: [type: :string, required: true])

      weather =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [city: [type: :string, required: true]],
          callback: fn _ -> {:ok, "sunny"} end
        )

      time =
        ReqLLM.Tool.new!(
          name: "get_time",
          description: "Get the time",
          parameter_schema: [],
          callback: fn _ -> {:ok, "now"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-3-flash",
          operation: :object,
          compiled_schema: schema,
          tools: [weather, time],
          tool_choice: :validated
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["generationConfig"]["responseMimeType"] == "application/json"
      assert decoded["generationConfig"]["responseJsonSchema"]["type"] == "object"

      assert [%{"functionDeclarations" => declarations}] = decoded["tools"]
      assert Enum.map(declarations, & &1["name"]) == ["get_weather", "get_time"]
      assert decoded["toolConfig"]["functionCallingConfig"]["mode"] == "VALIDATED"
    end

    test "encode_object_body omits grounding and URL context tools" do
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [city: [type: :string, required: true]],
          callback: fn _ -> {:ok, "sunny"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-3-flash",
          operation: :object,
          compiled_schema: schema,
          tools: [tool],
          google_grounding: %{enable: true},
          google_url_context: true
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert [%{"functionDeclarations" => [%{"name" => "get_weather"}]}] = decoded["tools"]

      refute Enum.any?(decoded["tools"], fn entry ->
               Map.has_key?(entry, "google_search") or Map.has_key?(entry, "url_context")
             end)
    end

    test "decode_response for :object preserves function calls and thought signatures" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{"city" => "Madrid"},
                    "id" => "call-1"
                  },
                  "thoughtSignature" => "sig_abc"
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ]
      }

      mock_resp = %Req.Response{status: 200, body: google_response}
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, operation: :object, model: "gemini-3-flash"]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})
      response = resp.body

      assert [tool_call] = ReqLLM.Response.tool_calls(response)
      assert tool_call.function.name == "get_weather"
      assert tool_call.id == "call-1"
      assert Jason.decode!(tool_call.function.arguments) == %{"city" => "Madrid"}
      assert ReqLLM.Response.finish_reason(response) == :tool_calls
      assert response.object == nil
      assert ReqLLM.ToolCall.metadata(tool_call)[:thought_signature] == "sig_abc"
    end
  end
end
