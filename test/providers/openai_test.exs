defmodule ReqLLM.Providers.OpenAITest do
  @moduledoc """
  Provider-level tests for OpenAI implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.OpenAI

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenAI

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(OpenAI.provider_id())
      assert is_binary(OpenAI.base_url())
      assert String.starts_with?(OpenAI.base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = OpenAI.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = OpenAI.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = OpenAI.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = OpenAI.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured chat request" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "prepare_request creates configured embedding request" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-small")
      text = "Hello, world!"
      opts = [provider_options: [dimensions: 512]]

      {:ok, request} = OpenAI.prepare_request(:embedding, model, text, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/embeddings"
      assert request.method == :post
    end

    test "prepare_request configures authentication and pipeline for chat" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      prompt = "Hello, world!"
      opts = [temperature: 0.5, max_tokens: 50]

      {:ok, request} = OpenAI.prepare_request(:chat, model, prompt, opts)

      # Verify core options
      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50
      assert String.starts_with?(List.first(request.headers["authorization"]), "Bearer test-key-")

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "prepare_request configures authentication and pipeline for embedding" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-small")
      text = "Hello, world!"
      opts = [provider_options: [dimensions: 512]]

      {:ok, request} = OpenAI.prepare_request(:embedding, model, text, opts)

      # Verify embedding-specific options
      assert request.options[:model] == model.model
      assert request.options[:operation] == :embedding
      assert request.options[:text] == "Hello, world!"
      assert request.options[:provider_options][:dimensions] == 512

      # Verify authentication
      assert String.starts_with?(List.first(request.headers["authorization"]), "Bearer test-key-")
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = OpenAI.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model("groq:llama-3.1-8b-instant")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> OpenAI.attach(wrong_model, [])
      end
    end

    test "prepare_request uses longer timeout for reasoning models (Responses API)" do
      {:ok, chat_model} = ReqLLM.model("openai:gpt-4o")
      {:ok, reasoning_model} = ReqLLM.model("openai:gpt-5")
      context = context_fixture()

      {:ok, chat_request} = OpenAI.prepare_request(:chat, chat_model, context, [])
      {:ok, reasoning_request} = OpenAI.prepare_request(:chat, reasoning_model, context, [])

      chat_timeout = chat_request.options[:receive_timeout]
      reasoning_timeout = reasoning_request.options[:receive_timeout]

      assert reasoning_timeout >= chat_timeout
      assert reasoning_timeout >= 300_000
    end

    test "prepare_request respects user-specified receive_timeout" do
      {:ok, model} = ReqLLM.model("openai:gpt-5")
      context = context_fixture()

      {:ok, request} = OpenAI.prepare_request(:chat, model, context, receive_timeout: 60_000)

      assert request.options[:receive_timeout] == 60_000
    end
  end

  describe "body encoding & context translation" do
    test "encode_body for chat without tools" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
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
      updated_request = OpenAI.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "gpt-4o"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      [system_msg, user_msg] = decoded["messages"]
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"
    end

    test "encode_body for chat with tools but no tool_choice" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
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

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      refute Map.has_key?(decoded, "tool_choice")

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["function"]["name"] == "test_tool"
    end

    test "encode_body for chat with tools and tool_choice" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      tool_choice = %{type: "function", function: %{name: "specific_tool"}}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: tool_choice
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "specific_tool"}
             }
    end

    test "encode_body for chat with tool_choice as string" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: "required"
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == "required"
    end

    test "encode_body for chat with tool_choice as atom" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: :required
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == "required"
    end

    test "encode_body for o1 models uses max_completion_tokens" do
      {:ok, model} = ReqLLM.model("openai:o1-mini")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          max_completion_tokens: 1000
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "o1-mini"
      assert decoded["max_completion_tokens"] == 1000
      refute Map.has_key?(decoded, "max_tokens")
      refute Map.has_key?(decoded, "temperature")
    end

    test "encode_body for o3 models uses max_completion_tokens" do
      {:ok, model} = ReqLLM.model("openai:o3-mini")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          max_completion_tokens: 2000
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "o3-mini"
      assert decoded["max_completion_tokens"] == 2000
      refute Map.has_key?(decoded, "max_tokens")
      refute Map.has_key?(decoded, "temperature")
    end

    test "encode_body for gpt-5 models uses max_completion_tokens" do
      {:ok, model} = ReqLLM.model("openai:gpt-5")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          max_completion_tokens: 2500,
          temperature: 0.7
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "gpt-5"
      assert decoded["max_completion_tokens"] == 2500
      assert decoded["temperature"] == 0.7
      refute Map.has_key?(decoded, "max_tokens")
    end

    test "encode_body for o4 models uses max_completion_tokens" do
      {:ok, model} = ReqLLM.model("openai:o4-mini")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          max_completion_tokens: 3000
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "o4-mini"
      assert decoded["max_completion_tokens"] == 3000
      refute Map.has_key?(decoded, "max_tokens")
      refute Map.has_key?(decoded, "temperature")
    end

    test "encode_body for regular models uses max_tokens" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          max_tokens: 1500,
          temperature: 0.7
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "gpt-4o"
      assert decoded["max_tokens"] == 1500
      assert decoded["temperature"] == 0.7
      refute Map.has_key?(decoded, "max_completion_tokens")
    end

    test "encode_body for embedding operation" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-small")
      text = "Hello, world!"

      mock_request = %Req.Request{
        options: [
          operation: :embedding,
          model: model.model,
          text: text,
          dimensions: 512
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "text-embedding-3-small"
      assert decoded["input"] == "Hello, world!"
      assert decoded["dimensions"] == 512
    end
  end

  describe "response decoding" do
    test "decode_response for chat handles non-streaming responses" do
      # Create a mock non-streaming response body
      mock_response_body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "created" => 1_677_652_288,
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help you today?"
            },
            "logprobs" => nil,
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 13,
          "completion_tokens" => 7,
          "total_tokens" => 20
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: mock_response_body
      }

      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      # Test decode_response directly
      {req, resp} = OpenAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.model == model.model
      assert response.stream? == false

      # Verify message normalization
      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert is_binary(text)
      assert String.length(text) > 0
      assert response.finish_reason in [:stop, :length]

      # Verify usage normalization
      assert is_integer(response.usage.input_tokens)
      assert is_integer(response.usage.output_tokens)
      assert is_integer(response.usage.total_tokens)

      # Verify context advancement (original + assistant)
      assert length(response.context.messages) == 3
      assert List.last(response.context.messages).role == :assistant
    end

    test "decode_response for chat handles streaming responses" do
      # Create mock streaming chunks
      stream_chunks = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}}]},
        %{"choices" => [%{"finish_reason" => "stop"}]}
      ]

      # Create a mock stream for real-time streaming
      mock_real_time_stream = Stream.map(stream_chunks, & &1)

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: nil
      }

      # Create a mock request with context, model, and real-time stream
      context = context_fixture()
      model = "gpt-4o"

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model],
        private: %{real_time_stream: mock_real_time_stream}
      }

      # Test decode_response directly
      {req, resp} = OpenAI.decode_response({mock_req, mock_resp})

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
      # http_task removed after fix for issue #42 (no duplicate request execution)
      assert response.provider_meta == %{}
    end

    test "decode_response for embedding returns raw body" do
      # Create a mock embedding response body
      mock_response_body = %{
        "object" => "list",
        "data" => [
          %{
            "object" => "embedding",
            "embedding" => [0.1, 0.2, 0.3],
            "index" => 0
          }
        ],
        "model" => "text-embedding-3-small",
        "usage" => %{
          "prompt_tokens" => 5,
          "total_tokens" => 5
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: mock_response_body
      }

      mock_req = %Req.Request{
        options: [operation: :embedding, id: "text-embedding-3-small"]
      }

      # Test decode_response for embeddings
      {req, resp} = OpenAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      # For embeddings, body should be the raw parsed JSON
      assert resp.body == mock_response_body
    end

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "error" => %{
          "message" => "Invalid API key provided",
          "type" => "invalid_request_error",
          "code" => "invalid_api_key"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, model: "gpt-4o"]
      }

      # Test decode_response error handling (now delegated to ChatAPI)
      {req, error} = OpenAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason == "OpenAI API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "provider implements translate_options/3" do
      assert function_exported?(OpenAI, :translate_options, 3)
    end

    test "translate_options passes through normal options unchanged" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")

      # Test that normal translation returns options unchanged
      opts = [temperature: 0.7, max_tokens: 1000]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts == opts
      assert warnings == []
    end

    test "translate_options for o1 models renames max_tokens and drops sampling params" do
      {:ok, model} = ReqLLM.model("openai:o1-mini")

      opts = [max_tokens: 1000, temperature: 0.7, top_p: 0.9]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 1000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      refute Keyword.has_key?(translated_opts, :top_p)
      assert length(warnings) == 3
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
      assert Enum.any?(warnings, &(&1 =~ "sampling parameters"))
    end

    test "translate_options for o3 models renames max_tokens and drops temperature" do
      {:ok, model} = ReqLLM.model("openai:o3-mini")

      opts = [max_tokens: 2000, temperature: 1.0, frequency_penalty: 0.1]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 2000
      assert translated_opts[:frequency_penalty] == 0.1
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      assert length(warnings) == 2
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
      assert Enum.any?(warnings, &(&1 =~ ":temperature"))
    end

    test "translate_options for regular models passes through unchanged" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")

      opts = [max_tokens: 1000, temperature: 0.7, top_p: 0.9]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts == opts
      assert warnings == []
    end

    test "translate_options for gpt-5 models renames max_tokens and drops sampling params" do
      {:ok, model} = ReqLLM.model("openai:gpt-5")
      opts = [max_tokens: 1500, temperature: 0.7, top_p: 0.9]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 1500
      refute Keyword.has_key?(translated_opts, :temperature)
      refute Keyword.has_key?(translated_opts, :top_p)
      refute Keyword.has_key?(translated_opts, :max_tokens)
      assert length(warnings) == 3
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
      assert Enum.any?(warnings, &(&1 =~ "sampling parameters"))
    end

    test "translate_options for gpt-5-mini models renames max_tokens and drops sampling params" do
      {:ok, model} = ReqLLM.model("openai:gpt-5-mini")
      opts = [max_tokens: 2500, temperature: 0.5]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 2500
      refute Keyword.has_key?(translated_opts, :temperature)
      refute Keyword.has_key?(translated_opts, :max_tokens)
      assert length(warnings) == 2
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
      assert Enum.any?(warnings, &(&1 =~ "sampling parameters"))
    end

    test "translate_options for o4 models renames max_tokens and drops temperature" do
      {:ok, model} = ReqLLM.model("openai:o4-mini")
      opts = [max_tokens: 3000, temperature: 0.8]
      {translated_opts, warnings} = OpenAI.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 3000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      assert length(warnings) == 2
      assert Enum.any?(warnings, &(&1 =~ "max_tokens"))
      assert Enum.any?(warnings, &(&1 =~ ":temperature"))
    end

    test "translate_options for non-chat operations passes through unchanged" do
      {:ok, model} = ReqLLM.model("openai:o1-mini")

      opts = [max_tokens: 1000, temperature: 0.7]
      {translated_opts, warnings} = OpenAI.translate_options(:embedding, model, opts)

      assert translated_opts == opts
      assert warnings == []
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 15,
          "completion_tokens" => 25,
          "total_tokens" => 40
        }
      }

      {:ok, usage} = OpenAI.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 15
      assert usage["completion_tokens"] == 25
      assert usage["total_tokens"] == 40
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = OpenAI.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")

      {:error, :invalid_body} = OpenAI.extract_usage("invalid", model)
      {:error, :invalid_body} = OpenAI.extract_usage(nil, model)
      {:error, :invalid_body} = OpenAI.extract_usage(123, model)
    end
  end

  describe "embedding support" do
    test "prepare_request for embedding with all options" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-large")
      text = "Sample text for embedding"
      opts = [dimensions: 1024, encoding_format: "float", user: "test-user"]

      {:ok, request} = OpenAI.prepare_request(:embedding, model, text, opts)

      assert request.options[:operation] == :embedding
      assert request.options[:text] == text
      assert request.options[:dimensions] == 1024
      assert request.options[:encoding_format] == "float"
      assert request.options[:user] == "test-user"
    end

    test "encode_body for embedding with optional parameters" do
      {:ok, model} = ReqLLM.model("openai:text-embedding-3-large")

      mock_request = %Req.Request{
        options: [
          operation: :embedding,
          model: model.model,
          text: "Test embedding text",
          provider_options: [dimensions: 512, encoding_format: "base64"],
          user: "test-user-123"
        ]
      }

      updated_request = OpenAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "text-embedding-3-large"
      assert decoded["input"] == "Test embedding text"
      assert decoded["dimensions"] == 512
      assert decoded["encoding_format"] == "base64"
      assert decoded["user"] == "test-user-123"
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

    test "prepare_request rejects unsupported operations" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = context_fixture()

      {:error, error} = OpenAI.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :unsupported not supported by OpenAI provider"
    end

    test "attach rejects invalid model provider" do
      {:ok, wrong_model} = ReqLLM.model("groq:llama-3.1-8b-instant")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> OpenAI.attach(wrong_model, [])
      end
    end
  end

  describe "ResponsesAPI json_schema support" do
    test "ResponsesAPI encode_text_format transforms response_format to flattened text.format" do
      schema = [
        name: [type: :string, required: true],
        title: [type: :string, required: true]
      ]

      json_schema = ReqLLM.Schema.to_json(schema)

      # Enforce strict schema requirements
      json_schema =
        json_schema
        |> Map.put("required", Map.keys(json_schema["properties"]))
        |> Map.put("additionalProperties", false)

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "output_schema",
          strict: true,
          schema: json_schema
        }
      }

      # Test the encode_text_format function
      text_format = ReqLLM.Providers.OpenAI.ResponsesAPI.encode_text_format(response_format)

      # ResponsesAPI expects flattened structure: text.format.{name, strict, schema}
      # not text.format.json_schema.{name, strict, schema}
      assert text_format["format"]["type"] == "json_schema"
      assert text_format["format"]["name"] == "output_schema"
      assert text_format["format"]["strict"] == true
      assert text_format["format"]["schema"] != nil
      refute Map.has_key?(text_format["format"], "json_schema")
    end

    test "ResponsesAPI includes text parameter in request body with name at format level" do
      {:ok, model} = ReqLLM.model("openai:gpt-5-nano")

      schema = [
        name: [type: :string, required: true],
        title: [type: :string, required: true]
      ]

      json_schema = ReqLLM.Schema.to_json(schema)

      # Enforce strict schema requirements
      json_schema =
        json_schema
        |> Map.put("required", Map.keys(json_schema["properties"]))
        |> Map.put("additionalProperties", false)

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "output_schema",
          strict: true,
          schema: json_schema
        }
      }

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [%ReqLLM.Message.ContentPart{type: :text, text: "Generate a person"}]
          }
        ]
      }

      opts = [
        provider_options: [response_format: response_format],
        context: context,
        model: model.model
      ]

      # Create a mock request
      request = %Req.Request{
        url: URI.parse("https://api.openai.com/v1/responses"),
        method: :post,
        options: opts
      }

      # Test encode_body
      encoded_request = ReqLLM.Providers.OpenAI.ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded_request.body)

      # Verify text parameter exists with correct structure
      # OpenAI ResponsesAPI expects name at text.format.name level, not text.format.json_schema.name
      assert Map.has_key?(body, "text")
      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "output_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"] != nil
      assert body["text"]["format"]["schema"]["type"] == "object"
      assert Map.has_key?(body["text"]["format"]["schema"], "properties")
    end

    test "ResponsesAPI decode_response extracts and validates object from json_schema response" do
      {:ok, model} = ReqLLM.model("openai:gpt-5-nano")

      schema = [
        name: [type: :string, required: true]
      ]

      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      # Mock a ResponsesAPI response with JSON in output_text
      mock_response_body = %{
        "id" => "resp_test123",
        "model" => "gpt-5-nano-2025-08-07",
        "object" => "response",
        "status" => "completed",
        "output" => [],
        "output_text" => ~s({"name":"Mara Ellington"}),
        "usage" => %{
          "input_tokens" => 31,
          "output_tokens" => 594,
          "reasoning_tokens" => 576
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: mock_response_body
      }

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [%ReqLLM.Message.ContentPart{type: :text, text: "Generate a person"}]
          }
        ]
      }

      mock_req = %Req.Request{
        options: [
          context: context,
          model: model.model,
          operation: :object,
          compiled_schema: compiled_schema
        ]
      }

      # Test decode_response
      {req, resp} = ReqLLM.Providers.OpenAI.ResponsesAPI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body

      # The object field should be populated with the parsed and validated JSON
      assert response.object != nil
      assert response.object["name"] == "Mara Ellington"

      # The message should still contain the original JSON text
      text = ReqLLM.Response.text(response)
      assert text == ~s({"name":"Mara Ellington"})
    end
  end
end
