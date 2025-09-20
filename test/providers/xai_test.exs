defmodule ReqLLM.Providers.XAITest do
  @moduledoc """
  Provider-level tests for xAI implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.XAI

  import ReqLLM.ProviderTestHelpers

  alias ReqLLM.Context
  alias ReqLLM.Providers.XAI

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(XAI.provider_id())
      assert is_binary(XAI.default_base_url())
      assert String.starts_with?(XAI.default_base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = XAI.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "supported options include core generation keys" do
      supported = XAI.supported_provider_options()
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      # All core keys should be supported (except meta-keys like :provider_options)
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- supported
      assert missing == [], "Missing core generation keys: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = XAI.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = XAI.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()
      opts = [temperature: 0.7, provider_options: [max_completion_tokens: 100]]

      {:ok, request} = XAI.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      model = ReqLLM.Model.from!("xai:grok-3")
      opts = [temperature: 0.5, provider_options: [max_completion_tokens: 50]]

      request = Req.new() |> XAI.attach(model, opts)

      # Verify authentication header (not options since that's done in prepare_request)
      assert request.headers["authorization"] |> Enum.any?(&String.starts_with?(&1, "Bearer "))

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = XAI.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      wrong_model = ReqLLM.Model.from!("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> XAI.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body without tools" do
      model = ReqLLM.Model.from!("xai:grok-3")
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
      updated_request = XAI.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "grok-3"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      [system_msg, user_msg] = decoded["messages"]
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"
    end

    test "encode_body with tools but no tool_choice" do
      model = ReqLLM.Model.from!("xai:grok-3")
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

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      refute Map.has_key?(decoded, "tool_choice")

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["function"]["name"] == "test_tool"
    end

    test "encode_body with tools and tool_choice" do
      model = ReqLLM.Model.from!("xai:grok-3")
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

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "specific_tool"}
             }
    end

    test "encode_body with response_format" do
      model = ReqLLM.Model.from!("xai:grok-3")
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

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["response_format"] == %{"type" => "json_object"}
    end

    test "encode_body xAI-specific options with skip values" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      test_cases = [
        # Skip values should not appear in JSON
        {[parallel_tool_calls: true],
         fn json -> refute Map.has_key?(json, "parallel_tool_calls") end},
        # Non-skip values should appear
        {[parallel_tool_calls: false],
         fn json -> assert json["parallel_tool_calls"] == false end},
        {[max_completion_tokens: 1024],
         fn json -> assert json["max_completion_tokens"] == 1024 end},
        {[reasoning_effort: "low"], fn json -> assert json["reasoning_effort"] == "low" end},
        {[search_parameters: %{mode: "on"}],
         fn json ->
           assert json["search_parameters"] == %{"mode" => "on"}
         end},
        {[stream_options: %{include_usage: true}],
         fn json ->
           assert json["stream_options"] == %{"include_usage" => true}
         end}
      ]

      for {opts, assertion} <- test_cases do
        mock_request = %Req.Request{
          options: [context: context, model: model.model, stream: false] ++ opts
        }

        updated_request = XAI.encode_body(mock_request)
        decoded = Jason.decode!(updated_request.body)
        assertion.(decoded)
      end
    end
  end

  describe "response decoding" do
    test "decode_response handles non-streaming responses" do
      # Create a mock OpenAI-style response body
      response_body = %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion",
        "created" => System.os_time(:second),
        "model" => "grok-3",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help you today?"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 12,
          "completion_tokens" => 8,
          "total_tokens" => 20
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: response_body
      }

      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false]
      }

      # Test decode_response directly
      {req, resp} = XAI.decode_response({mock_req, mock_resp})

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
      assert response.finish_reason in [:stop, :length, "stop", "length"]

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
      model = "grok-3"

      # Mock the real-time stream that would be created by the Stream step
      mock_stream = ["Hello", " world", "!"]

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model],
        private: %{real_time_stream: mock_stream}
      }

      # Test decode_response directly  
      {req, resp} = XAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert response.stream == mock_stream
      assert response.model == model

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2

      # Verify stream structure and processing
      assert response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      assert response.finish_reason == nil
      assert is_map(response.provider_meta)
      assert Map.has_key?(response.provider_meta, :http_task)
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
        options: [context: context, model: "grok-3"]
      }

      # Test decode_response error handling
      {req, error} = XAI.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason == "xAI API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "provider implements translate_options/3" do
      # xAI implements translate_options/3 for various alias handling
      assert function_exported?(XAI, :translate_options, 3)
    end

    test "translate_options handles stream? alias" do
      model = ReqLLM.Model.from!("xai:grok-3")

      # Test stream? -> stream translation
      opts = [temperature: 0.7, stream?: true]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :stream) == true
      refute Keyword.has_key?(translated_opts, :stream?)
      assert warnings == []
    end

    test "translate_options handles max_tokens -> max_completion_tokens preference" do
      model = ReqLLM.Model.from!("xai:grok-4")

      opts = [temperature: 0.7, max_tokens: 1000]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :max_completion_tokens) == 1000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      assert length(warnings) == 1
      assert hd(warnings) =~ "max_completion_tokens"
    end

    test "translate_options handles web_search_options -> search_parameters alias" do
      model = ReqLLM.Model.from!("xai:grok-3")

      opts = [web_search_options: %{mode: "auto"}]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :search_parameters) == %{mode: "auto"}
      refute Keyword.has_key?(translated_opts, :web_search_options)
      assert length(warnings) == 1
      assert hd(warnings) =~ "deprecated"
    end

    test "translate_options removes unsupported parameters with warnings" do
      model = ReqLLM.Model.from!("xai:grok-3")

      opts = [temperature: 0.7, logit_bias: %{"123" => 10}, service_tier: "auto"]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      refute Keyword.has_key?(translated_opts, :logit_bias)
      refute Keyword.has_key?(translated_opts, :service_tier)
      assert Keyword.get(translated_opts, :temperature) == 0.7

      assert length(warnings) == 2
      warning_text = Enum.join(warnings, " ")
      assert warning_text =~ "logit_bias"
      assert warning_text =~ "service_tier"
    end

    test "translate_options validates reasoning_effort model compatibility" do
      # Should work with grok-3-mini
      grok_3_mini = ReqLLM.Model.from!("xai:grok-3-mini")
      opts = [reasoning_effort: "high"]
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_3_mini, opts)

      assert Keyword.get(translated_opts, :reasoning_effort) == "high"
      assert warnings == []

      # Should be removed with warning for grok-4
      grok_4 = ReqLLM.Model.from!("xai:grok-4")
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_4, opts)

      refute Keyword.has_key?(translated_opts, :reasoning_effort)
      assert length(warnings) == 1
      assert hd(warnings) =~ "Grok-4"
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = XAI.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = XAI.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      model = ReqLLM.Model.from!("xai:grok-3")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = XAI.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 10
      assert usage["completion_tokens"] == 20
      assert usage["total_tokens"] == 30
    end

    test "extract_usage with missing usage data" do
      model = ReqLLM.Model.from!("xai:grok-3")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = XAI.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      model = ReqLLM.Model.from!("xai:grok-3")

      {:error, :invalid_body} = XAI.extract_usage("invalid", model)
      {:error, :invalid_body} = XAI.extract_usage(nil, model)
      {:error, :invalid_body} = XAI.extract_usage(123, model)
    end
  end

  describe "object generation edge cases" do
    test "prepare_request for :object with low max_completion_tokens gets adjusted" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      # Test with max_completion_tokens < 200
      opts = [provider_options: [max_completion_tokens: 50], compiled_schema: schema]
      {:ok, request} = XAI.prepare_request(:object, model, context, opts)

      # Should be adjusted to 200
      assert request.options[:max_completion_tokens] == 200
    end

    test "prepare_request for :object with nil max_completion_tokens gets default" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile([])

      # No max_completion_tokens specified
      opts = [compiled_schema: schema]
      {:ok, request} = XAI.prepare_request(:object, model, context, opts)

      # Should get default of 4096
      assert request.options[:max_completion_tokens] == 4096
    end

    test "prepare_request for :object with sufficient max_completion_tokens unchanged" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(value: [type: :integer])

      opts = [provider_options: [max_completion_tokens: 1000], compiled_schema: schema]
      {:ok, request} = XAI.prepare_request(:object, model, context, opts)

      # Should remain unchanged
      assert request.options[:max_completion_tokens] == 1000
    end

    test "prepare_request rejects unsupported operations" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      # Test unsupported operation for 3-arg version
      {:error, error} = XAI.prepare_request(:embedding, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"

      # Test unsupported operation for object with schema  
      {:ok, schema} = ReqLLM.Schema.compile([])
      {:error, error} = XAI.prepare_request(:embedding, model, context, compiled_schema: schema)
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"
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

  describe "xAI-specific features" do
    test "Live Search parameters are encoded correctly" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      search_params = %{
        mode: "on",
        sources: [%{type: "web"}],
        from_date: "2024-01-01",
        to_date: "2024-12-31",
        return_citations: true
      }

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          search_parameters: search_params
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["search_parameters"] == %{
               "mode" => "on",
               "sources" => [%{"type" => "web"}],
               "from_date" => "2024-01-01",
               "to_date" => "2024-12-31",
               "return_citations" => true
             }
    end

    test "reasoning_effort parameter validation by model type" do
      # Test grok-3-mini accepts reasoning_effort
      grok_3_mini = ReqLLM.Model.from!("xai:grok-3-mini")
      opts = [reasoning_effort: "medium"]
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_3_mini, opts)

      assert Keyword.get(translated_opts, :reasoning_effort) == "medium"
      assert warnings == []

      # Test grok-4 rejects reasoning_effort
      grok_4 = ReqLLM.Model.from!("xai:grok-4")
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_4, opts)

      refute Keyword.has_key?(translated_opts, :reasoning_effort)
      assert length(warnings) == 1
      assert hd(warnings) =~ "not supported for Grok-4"
    end

    test "stream_options encoding for usage reporting" do
      model = ReqLLM.Model.from!("xai:grok-3")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: true,
          stream_options: %{include_usage: true}
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["stream"] == true
      assert decoded["stream_options"] == %{"include_usage" => true}
    end
  end
end
