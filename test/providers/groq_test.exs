defmodule ReqLLM.Providers.GroqTest do
  @moduledoc """
  Provider-level tests for Groq implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Groq

  import ReqLLM.ProviderTestHelpers

  alias ReqLLM.Context
  alias ReqLLM.Providers.Groq

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Groq.provider_id())
      assert is_binary(Groq.default_base_url())
      assert String.starts_with?(Groq.default_base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = Groq.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Generation.schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "supported options include core generation keys" do
      supported = Groq.supported_provider_options()
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      # All core keys should be supported (except meta-keys like :provider_options)
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- supported
      assert missing == [], "Missing core generation keys: #{inspect(missing)}"
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Groq.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Groq.attach(model, opts)

      # Verify core options
      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50
      assert {:bearer, _key} = request.options[:auth]

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = Groq.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      wrong_model = ReqLLM.Model.from!("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Groq.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body produces correct JSON structure" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
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

      [system_msg, user_msg] = decoded["messages"]
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"
    end

    test "encode_body handles options correctly" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
      context = context_fixture()

      test_cases = [
        {[context: context, model: model.model, stream: false],
         fn json -> refute Map.has_key?(json, "temperature") end},
        {[context: context, model: model.model, stream: false, temperature: 0.2, max_tokens: 55],
         fn json ->
           assert json["temperature"] == 0.2
           assert json["max_tokens"] == 55
         end},
        {[context: context, model: model.model, stream: false, reasoning_effort: "high"],
         fn json -> assert json["reasoning_effort"] == "high" end}
      ]

      for {options, assertion} <- test_cases do
        mock_request = %Req.Request{options: options}
        updated_request = Groq.encode_body(mock_request)
        decoded = Jason.decode!(updated_request.body)
        assertion.(decoded)
      end
    end

    test "encode_body handles tools correctly" do
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
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

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["function"]["name"] == "test_tool"
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
      model = ReqLLM.Model.from!("groq:llama-3.1-8b-instant")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false]
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
      # Create mock streaming chunks
      stream_chunks = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}}]},
        %{"choices" => [%{"finish_reason" => "stop"}]}
      ]

      # Create a mock stream
      mock_stream = Stream.map(stream_chunks, & &1)

      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: mock_stream
      }

      # Create a mock request with context
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: true]
      }

      # Test decode_response directly  
      {req, resp} = Groq.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert is_struct(response.stream, Stream)

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2
    end
  end

  describe "option translation" do
    test "provider does not implement translate_options/3" do
      # Most providers don't implement translate_options/3, verify this
      refute function_exported?(Groq, :translate_options, 3)
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

  describe "error handling & robustness" do
    test "context validation" do
      # Multiple system messages should fail
      invalid_context =
        Context.new([
          Context.system("System 1"),
          Context.system("System 2"),
          Context.user("Hello")
        ])

      assert_raise ArgumentError, ~r/should have exactly one system message/, fn ->
        Context.validate!(invalid_context)
      end
    end
  end
end
