defmodule ReqLLM.Providers.GoogleTest do
  @moduledoc """
  Provider-level tests for Google implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Google.provider_id())
      assert is_binary(Google.base_url())
      assert String.starts_with?(Google.base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = Google.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = Google.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = Google.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = Google.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Google.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/models/#{model.model}:generateContent"
      assert request.method == :post
    end

    test "prepare_request for streaming creates streaming endpoint" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100, stream: true]

      {:ok, request} = Google.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/models/#{model.model}:streamGenerateContent"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Google.attach(model, opts)

      # Verify core options
      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50

      # Google uses query parameter authentication
      assert request.options[:params][:key] != nil

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = Google.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Google.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body without tools" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Create a mock request with the expected structure
      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      # Test the encode_body function directly
      updated_request = Google.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      # Should have Google's structure
      assert is_list(decoded["contents"])
      # Only user message, system is separate
      assert length(decoded["contents"]) == 1
      refute Map.has_key?(decoded, "tools")

      # Check generationConfig
      assert Map.has_key?(decoded, "generationConfig")
      assert decoded["generationConfig"]["candidateCount"] == 1

      # Check system instruction is separate
      assert Map.has_key?(decoded, "systemInstruction")
      assert decoded["systemInstruction"]["parts"]

      # Only user message in contents now
      [user_msg] = decoded["contents"]
      assert user_msg["role"] == "user"
      assert is_list(user_msg["parts"])
    end

    test "encode_body with tools but no tool_choice" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
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
          tools: [tool],
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [tool_def] = decoded["tools"]
      assert Map.has_key?(tool_def, "functionDeclarations")
      assert is_list(tool_def["functionDeclarations"])
    end

    test "encode_body with Google-specific options" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      safety_settings = [
        %{
          "category" => "HARM_CATEGORY_HARASSMENT",
          "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
        }
      ]

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          google_safety_settings: safety_settings,
          google_candidate_count: 2,
          temperature: 0.8,
          max_tokens: 500
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      # Check safety settings
      assert decoded["safetySettings"] == safety_settings

      # Check generation config with Google parameter names
      gen_config = decoded["generationConfig"]
      assert gen_config["temperature"] == 0.8
      assert gen_config["maxOutputTokens"] == 500
      assert gen_config["candidateCount"] == 2
    end

    test "encode_body for embedding operation" do
      mock_request = %Req.Request{
        options: [
          operation: :embedding,
          id: "gemini-embedding-001",
          text: "Hello, world!",
          dimensions: 768
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      # Check embedding-specific structure
      assert decoded["model"] == "models/gemini-embedding-001"
      assert decoded["content"]["parts"] == [%{"text" => "Hello, world!"}]
      assert decoded["outputDimensionality"] == 768
    end
  end

  describe "response decoding" do
    test "decode_response handles non-streaming responses" do
      # Create a mock Google response
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello there! How can I help you today?"}],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "safetyRatings" => []
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 25
        }
      }

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      # Test decode_response directly
      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.model == model.model
      assert response.stream? == false

      # Verify message normalization
      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert text == "Hello there! How can I help you today?"
      assert response.finish_reason == :stop

      # Verify usage normalization
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 15
      assert response.usage.total_tokens == 25

      # Verify context advancement (original + assistant)
      assert length(response.context.messages) == 3
      assert List.last(response.context.messages).role == :assistant
    end

    test "decode_response extracts cached token counts" do
      # Create a mock Google response with cached tokens
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Response using cached context"}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 1500,
          "candidatesTokenCount" => 50,
          "totalTokenCount" => 1550,
          "cachedContentTokenCount" => 1200
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = resp.body
      response = resp.body

      # Verify cached tokens are extracted
      assert response.usage.cached_tokens == 1200
      assert response.usage.input_tokens == 1500
      assert response.usage.output_tokens == 50
      assert response.usage.total_tokens == 1550
    end

    test "decode_response preserves tool calls" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "demo_tool",
                    "args" => %{"payload" => "value"},
                    "id" => "call-1"
                  }
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 3,
          "totalTokenCount" => 15
        }
      }

      mock_resp = %Req.Response{status: 200, body: google_response}

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "gemini-1.5-flash"]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      response = resp.body
      assert %ReqLLM.Response{} = response

      assert [tool_call] = ReqLLM.Response.tool_calls(response)
      assert tool_call.function.name == "demo_tool"
      assert tool_call.id == "call-1"
      # Bug #271 fix: Google returns "STOP" even with tool calls, but we correctly
      # detect tool calls and return :tool_calls finish_reason
      assert ReqLLM.Response.finish_reason(response) == :tool_calls
    end

    test "decode_response handles streaming responses" do
      # Create mock streaming chunks (Google format)
      stream_chunks = [
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => " world"}]}}]},
        %{"candidates" => [%{"finishReason" => "STOP"}]}
      ]

      # Create a mock stream
      mock_stream = Stream.map(stream_chunks, & &1)

      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: mock_stream
      }

      # Create a mock request with context and model
      context = context_fixture()
      model = "gemini-1.5-flash"

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model]
      }

      # Test decode_response directly
      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert is_struct(response.stream, Stream)
      assert response.model == model

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2

      # Verify stream structure and processing
      assert response.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               cached_tokens: 0,
               reasoning_tokens: 0
             }

      assert response.finish_reason == nil
      assert response.provider_meta == %{}
    end

    test "decode_response for embedding returns normalized OpenAI format" do
      embedding_response = %{
        "embedding" => %{
          "values" => [0.1, -0.2, 0.3, 0.4, -0.5]
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: embedding_response
      }

      mock_req = %Req.Request{
        options: [operation: :embedding, id: "gemini-embedding-001"]
      }

      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req

      assert resp.body == %{
               "data" => [%{"index" => 0, "embedding" => [0.1, -0.2, 0.3, 0.4, -0.5]}]
             }
    end

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "error" => %{
          "code" => 400,
          "message" => "Invalid API key",
          "status" => "INVALID_ARGUMENT"
        }
      }

      mock_resp = %Req.Response{
        status: 400,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "gemini-1.5-flash"]
      }

      # Test decode_response error handling
      {req, error} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 400
      assert error.reason == "Google API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "provider implements translate_options/3" do
      # Google implements translate_options/3 for stream? alias handling
      assert function_exported?(Google, :translate_options, 3)
    end

    test "translate_options handles stream? alias" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      # Test stream? -> stream translation
      opts = [temperature: 0.7, stream?: true]
      {translated_opts, warnings} = Google.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :stream) == true
      refute Keyword.has_key?(translated_opts, :stream?)
      assert warnings == []
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = Google.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = Google.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_with_usage = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      {:ok, usage} = Google.extract_usage(body_with_usage, model)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      body_without_usage = %{"candidates" => []}

      {:error, :no_usage_found} = Google.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      {:error, :invalid_body} = Google.extract_usage("invalid", model)
      {:error, :invalid_body} = Google.extract_usage(nil, model)
      {:error, :invalid_body} = Google.extract_usage(123, model)
    end

    test "extract_usage with cached content tokens" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_with_cached_tokens = %{
        "usageMetadata" => %{
          "promptTokenCount" => 500,
          "candidatesTokenCount" => 200,
          "totalTokenCount" => 700,
          "cachedContentTokenCount" => 120
        }
      }

      {:ok, usage} = Google.extract_usage(body_with_cached_tokens, model)
      assert usage.input_tokens == 500
      assert usage.output_tokens == 200
      assert usage.total_tokens == 700
      assert usage.cached_tokens == 120
    end

    test "extract_usage without cached content tokens" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_without_cached_tokens = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      {:ok, usage} = Google.extract_usage(body_without_cached_tokens, model)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
      assert usage.cached_tokens == 0
    end
  end

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

      assert request.options[:max_tokens] == 4096
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
      decoded = Jason.decode!(updated_request.body)

      assert decoded["generationConfig"]["responseMimeType"] == "application/json"
      assert decoded["generationConfig"]["candidateCount"] == 1
      assert Map.has_key?(decoded["generationConfig"], "responseSchema")
      refute Map.has_key?(decoded, "tools")
      refute Map.has_key?(decoded, "toolConfig")
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
      decoded = Jason.decode!(updated_request.body)

      response_schema = decoded["generationConfig"]["responseSchema"]
      assert response_schema["type"] == "OBJECT"
      assert Map.has_key?(response_schema, "properties")
      assert Map.has_key?(response_schema["properties"], "name")
      assert response_schema["properties"]["name"]["type"] == "STRING"
      refute Map.has_key?(decoded["generationConfig"], "responseJsonSchema")
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
      decoded = Jason.decode!(updated_request.body)

      response_json_schema = decoded["generationConfig"]["responseJsonSchema"]
      assert response_json_schema["type"] == "object"
      assert Map.has_key?(response_json_schema, "properties")
      refute Map.has_key?(decoded["generationConfig"], "responseSchema")
    end

    test "prepare_request creates configured embedding request" do
      {:ok, model} = ReqLLM.model("google:gemini-embedding-001")
      text = "Hello, world!"
      opts = [dimensions: 768]

      {:ok, request} = Google.prepare_request(:embedding, model, text, opts)

      assert request.method == :post
      assert request.url.path == "/models/gemini-embedding-001:embedContent"

      # Check request options contain embedding-specific data
      assert request.options[:text] == text
      assert request.options[:operation] == :embedding
      assert request.options[:dimensions] == 768
    end

    test "prepare_request rejects unsupported operations" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Test unsupported operation for 3-arg version
      {:error, error} = Google.prepare_request(:unsupported_operation, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :unsupported_operation not supported"

      # Test unsupported operation for object with schema
      {:ok, schema} = ReqLLM.Schema.compile([])

      {:error, error} =
        Google.prepare_request(:unsupported_operation, model, context, compiled_schema: schema)

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :unsupported_operation not supported"
    end
  end

  describe "error handling & robustness" do
    test "context validation" do
      # Multiple system messages should fail
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

  describe "file attachment support" do
    test "encode_body handles :file ContentPart with inline_data format" do
      file_content = "test file content"

      file_part = %ReqLLM.Message.ContentPart{
        type: :file,
        data: file_content,
        media_type: "application/pdf"
      }

      message_with_file = %ReqLLM.Message{
        role: :user,
        content: [file_part]
      }

      context = %ReqLLM.Context{messages: [message_with_file]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [user_msg] = decoded["contents"]
      parts = user_msg["parts"]

      assert length(parts) == 1, "Expected 1 part, got: #{inspect(parts)}"
      [part] = parts

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "application/pdf"
      assert Base.decode64!(part["inline_data"]["data"]) == file_content
    end

    test "encode_body handles video ContentPart with inline_data format" do
      video_content = "fake video bytes"

      video_part = %ReqLLM.Message.ContentPart{
        type: :file,
        data: video_content,
        media_type: "video/mp4"
      }

      message_with_video = %ReqLLM.Message{
        role: :user,
        content: [video_part]
      }

      context = %ReqLLM.Context{messages: [message_with_video]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "video/mp4"
      assert Base.decode64!(part["inline_data"]["data"]) == video_content
    end

    test "encode_body handles image ContentPart with inline_data format" do
      image_content = <<137, 80, 78, 71, 13, 10, 26, 10>>

      image_part = %ReqLLM.Message.ContentPart{
        type: :image,
        data: image_content,
        media_type: "image/png"
      }

      message_with_image = %ReqLLM.Message{
        role: :user,
        content: [image_part]
      }

      context = %ReqLLM.Context{messages: [message_with_image]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "image/png"
      assert Base.decode64!(part["inline_data"]["data"]) == image_content
    end
  end
end
