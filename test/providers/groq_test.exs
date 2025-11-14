defmodule ReqLLM.Providers.GroqTest do
  @moduledoc """
  Provider-level tests for Groq implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Groq

  alias ReqLLM.Context
  alias ReqLLM.Providers.Groq

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Groq.provider_id())
      assert is_binary(Groq.base_url())
      assert String.starts_with?(Groq.base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = Groq.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = Groq.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = Groq.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = Groq.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Groq.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Groq.attach(model, opts)

      # Verify authentication
      auth_header = Enum.find(request.headers, fn {name, _} -> name == "authorization" end)
      assert auth_header != nil
      {_, [auth_value]} = auth_header
      assert String.starts_with?(auth_value, "Bearer ")

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Hello world"

      # Unsupported operation
      {:error, error} = Groq.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Groq.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body without tools" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
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
      updated_request = Groq.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "llama-3.1-8b-instant"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      [system_msg, user_msg] = decoded["messages"]
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"
    end

    test "encode_body with tools but no tool_choice" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
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

      updated_request = Groq.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      refute Map.has_key?(decoded, "tool_choice")

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["function"]["name"] == "test_tool"
    end

    test "encode_body with tools and tool_choice" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
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

      updated_request = Groq.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "specific_tool"}
             }
    end

    test "encode_body with response_format" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      response_format = %{type: "json_object"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          response_format: response_format
        ]
      }

      updated_request = Groq.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["response_format"] == %{"type" => "json_object"}
    end

    test "encode_body provider-specific options with skip values" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      test_cases = [
        # Skip values should not appear in JSON
        {[service_tier: "auto"], fn json -> refute Map.has_key?(json, "service_tier") end},
        {[reasoning_effort: "default"],
         fn json -> refute Map.has_key?(json, "reasoning_effort") end},
        # Non-skip values should appear
        {[service_tier: "performance"],
         fn json -> assert json["service_tier"] == "performance" end},
        {[reasoning_effort: "high"], fn json -> assert json["reasoning_effort"] == "high" end},
        {[reasoning_format: "json"], fn json -> assert json["reasoning_format"] == "json" end},
        {[search_settings: %{domains: ["example.com"]}],
         fn json ->
           assert json["search_settings"] == %{"domains" => ["example.com"]}
         end}
      ]

      for {provider_opts, assertion} <- test_cases do
        options = [context: context, model: model.model, stream: false] ++ provider_opts
        mock_request = %Req.Request{options: options}
        updated_request = Groq.encode_body(mock_request)
        decoded = Jason.decode!(updated_request.body)
        assertion.(decoded)
      end
    end

    test "encode_body handles standard OpenAI options" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      test_cases = [
        {[temperature: 0.2, max_tokens: 55, top_p: 0.9, frequency_penalty: 0.1],
         fn json ->
           assert json["temperature"] == 0.2
           assert json["max_tokens"] == 55
           assert json["top_p"] == 0.9
           assert json["frequency_penalty"] == 0.1
         end},
        {[presence_penalty: 0.2, user: "test_user", seed: 12_345],
         fn json ->
           assert json["presence_penalty"] == 0.2
           assert json["user"] == "test_user"
           assert json["seed"] == 12_345
         end},
        {[logit_bias: %{"50256" => -100}],
         fn json -> assert json["logit_bias"] == %{"50256" => -100} end}
      ]

      for {options, assertion} <- test_cases do
        full_options = [context: context, model: model.model, stream: false] ++ options
        mock_request = %Req.Request{options: full_options}
        updated_request = Groq.encode_body(mock_request)
        decoded = Jason.decode!(updated_request.body)
        assertion.(decoded)
      end
    end
  end

  describe "response decoding & normalization" do
    test "decode_response handles non-streaming responses" do
      # Create a mock OpenAI-format response
      mock_json_response = openai_format_json_fixture()

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: mock_json_response
      }

      # Create a mock request with context
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "groq:llama-3.1-8b-instant"]
      }

      # Test decode_response directly
      {req, resp} = Groq.decode_response({mock_req, mock_resp})

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

    test "decode_response handles streaming responses" do
      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: []
      }

      # Create a mock request with context and model and real-time stream
      context = context_fixture()
      model = "llama-3.1-8b-instant"

      # Mock the real-time stream that would be created by the Stream step
      mock_stream = ["Hello", " world", "!"]

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model],
        private: %{real_time_stream: mock_stream}
      }

      # Test decode_response directly
      {req, resp} = Groq.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert response.stream == mock_stream
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
      assert is_map(response.provider_meta)
      # In test scenario with mock stream, no http_task is created
    end

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "error" => %{
          "message" => "Invalid API key",
          "type" => "authentication_error",
          "code" => "invalid_api_key"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "llama-3.1-8b-instant"]
      }

      # Test decode_response error handling
      {req, error} = Groq.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason =~ " API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "provider uses default translate_options/3" do
      # Groq uses default pass-through translate_options implementation
      assert function_exported?(Groq, :translate_options, 3)
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = Groq.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = Groq.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = Groq.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 10
      assert usage["completion_tokens"] == 20
      assert usage["total_tokens"] == 30
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = Groq.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")

      {:error, :invalid_body} = Groq.extract_usage("invalid", model)
      {:error, :invalid_body} = Groq.extract_usage(nil, model)
      {:error, :invalid_body} = Groq.extract_usage(123, model)
    end
  end

  describe "object generation edge cases" do
    test "prepare_request for :object with low max_tokens gets adjusted" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Generate a person"
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      # Test with max_tokens < 200
      opts = [max_tokens: 50, compiled_schema: schema]
      {:ok, request} = Groq.prepare_request(:object, model, prompt, opts)

      # Should be adjusted to 200
      assert request.options[:max_tokens] == 200
    end

    test "prepare_request for :object with nil max_tokens gets default" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Generate an object"
      {:ok, schema} = ReqLLM.Schema.compile([])

      # No max_tokens specified
      opts = [compiled_schema: schema]
      {:ok, request} = Groq.prepare_request(:object, model, prompt, opts)

      # Should get default of 4096
      assert request.options[:max_tokens] == 4096
    end

    test "prepare_request for :object with sufficient max_tokens unchanged" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Generate data"
      {:ok, schema} = ReqLLM.Schema.compile(value: [type: :integer])

      opts = [max_tokens: 1000, compiled_schema: schema]
      {:ok, request} = Groq.prepare_request(:object, model, prompt, opts)

      # Should remain unchanged
      assert request.options[:max_tokens] == 1000
    end

    test "prepare_request rejects unsupported operations" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Hello world"

      # Embedding is now supported via defaults, so test an actually unsupported operation
      {:error, error} = Groq.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :unsupported not supported"

      # Test unsupported operation for object with schema
      {:ok, schema} = ReqLLM.Schema.compile([])

      {:error, error} =
        Groq.prepare_request(:another_unsupported, model, prompt, compiled_schema: schema)

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :another_unsupported not supported"
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
                   ~r/Context should have at most one system message/,
                   fn ->
                     Context.validate!(invalid_context)
                   end
    end
  end
end
