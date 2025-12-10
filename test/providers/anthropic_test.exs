defmodule ReqLLM.Providers.AnthropicTest do
  @moduledoc """
  Provider-level tests for Anthropic implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic

  alias ReqLLM.Providers.Anthropic

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(Anthropic.provider_id())
      assert is_binary(Anthropic.base_url())
      assert String.starts_with?(Anthropic.base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = Anthropic.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = Anthropic.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      # All core keys should be in the extended schema
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      prompt = "Hello world"
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Anthropic.prepare_request(:chat, model, prompt, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/v1/messages"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Anthropic.attach(model, opts)

      # Verify authentication
      api_key_header = Enum.find(request.headers, fn {name, _} -> name == "x-api-key" end)
      assert api_key_header != nil

      version_header = Enum.find(request.headers, fn {name, _} -> name == "anthropic-version" end)
      assert version_header != nil

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "attach custom api_key option" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      custom_key = "custom_api_key_123"

      request =
        Req.new()
        |> Anthropic.attach(model, api_key: custom_key)

      assert request.options.api_key == custom_key
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      prompt = "Hello world"

      # Unsupported operation
      {:error, error} = Anthropic.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Anthropic.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body merges consecutive tool results into single user message" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are helpful."),
          ReqLLM.Context.user("What's the weather in Paris and London?"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "tool_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
              },
              %ReqLLM.ToolCall{
                id: "tool_2",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"London"})}
              }
            ]
          ),
          ReqLLM.Context.tool_result("tool_1", "22°C and sunny"),
          ReqLLM.Context.tool_result("tool_2", "18°C and cloudy")
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      messages = decoded["messages"]

      user_messages = Enum.filter(messages, &(&1["role"] == "user"))
      assert length(user_messages) == 2

      tool_result_msg = List.last(user_messages)
      assert is_list(tool_result_msg["content"])
      assert length(tool_result_msg["content"]) == 2

      [result1, result2] = tool_result_msg["content"]
      assert result1["type"] == "tool_result"
      assert result1["tool_use_id"] == "tool_1"
      assert result2["type"] == "tool_result"
      assert result2["tool_use_id"] == "tool_2"
    end

    test "encode_body without tools" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
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
      updated_request = Anthropic.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "claude-sonnet-4-5-20250929"
      assert is_list(decoded["messages"])
      # Only user message, system goes to top-level
      assert length(decoded["messages"]) == 1
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      # Check top-level system parameter (Anthropic format)
      assert decoded["system"] == "You are a helpful assistant."

      [user_msg] = decoded["messages"]
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Hello, how are you?"
    end

    test "encode_body with tools" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
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

      tool_choice = %{type: "tool", name: "test_tool"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: tool_choice
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      assert decoded["tool_choice"] == %{"type" => "tool", "name" => "test_tool"}

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["name"] == "test_tool"
      assert encoded_tool["description"] == "A test tool"
      assert is_map(encoded_tool["input_schema"])
    end

    test "encode_body normalizes tool_choice :required to Anthropic format" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [name: [type: :string, required: true]],
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

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      # :required should be normalized to %{type: "any"} for Anthropic
      assert decoded["tool_choice"] == %{"type" => "any"}
    end

    test "encode_body normalizes tool_choice :auto to Anthropic format" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [name: [type: :string, required: true]],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: :auto
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      # :auto should be normalized to %{type: "auto"} for Anthropic
      assert decoded["tool_choice"] == %{"type" => "auto"}
    end

    test "encode_body normalizes tool_choice {:tool, name} to Anthropic format" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [name: [type: :string, required: true]],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: {:tool, "test_tool"}
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      # {:tool, name} should be normalized to %{type: "tool", name: "..."} for Anthropic
      assert decoded["tool_choice"] == %{"type" => "tool", "name" => "test_tool"}
    end

    test "encode_request accepts map-based streaming tool calls" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      streaming_tool_call = %{
        id: "call_123",
        name: "get_time",
        arguments: %{"zone" => "UTC"}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What time is it?"),
          %ReqLLM.Message{role: :assistant, content: [], tool_calls: [streaming_tool_call]},
          ReqLLM.Context.tool_result("call_123", "10:00 UTC")
        ])

      request = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      messages = request[:messages]

      assert Enum.any?(messages, fn msg ->
               role = Map.get(msg, "role") || Map.get(msg, :role)
               content = Map.get(msg, "content") || Map.get(msg, :content)

               role == "assistant" and
                 Enum.any?(List.wrap(content), fn block ->
                   is_map(block) and
                     (Map.get(block, "type") || Map.get(block, :type)) == "tool_use" and
                     (Map.get(block, "name") || Map.get(block, :name)) == "get_time" and
                     (Map.get(block, "input") || Map.get(block, :input)) == %{"zone" => "UTC"}
                 end)
             end)

      assert Enum.any?(messages, fn msg ->
               role = Map.get(msg, "role") || Map.get(msg, :role)
               content = Map.get(msg, "content") || Map.get(msg, :content)

               role == "user" and
                 Enum.any?(List.wrap(content), fn block ->
                   is_map(block) and
                     (Map.get(block, "type") || Map.get(block, :type)) == "tool_result" and
                     (Map.get(block, "tool_use_id") || Map.get(block, :tool_use_id)) == "call_123"
                 end)
             end)
    end
  end

  describe "response decoding & normalization" do
    test "decode_response handles non-streaming responses" do
      # Create a mock Anthropic-format response
      mock_json_response = anthropic_format_json_fixture()

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: mock_json_response
      }

      # Create a mock request with context
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "anthropic:claude-sonnet-4-5-20250929"]
      }

      # Test decode_response directly
      {req, resp} = Anthropic.decode_response({mock_req, mock_resp})

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

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "type" => "error",
        "error" => %{
          "type" => "authentication_error",
          "message" => "Invalid API key"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "claude-sonnet-4-5-20250929"]
      }

      # Test decode_response error handling
      {req, error} = Anthropic.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason =~ "Anthropic API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "translate_options converts stop to stop_sequences" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      # Test single stop string
      {translated_opts, []} = Anthropic.translate_options(:chat, model, stop: "STOP")
      assert Keyword.get(translated_opts, :stop_sequences) == ["STOP"]
      assert Keyword.get(translated_opts, :stop) == nil

      # Test stop list
      {translated_opts, []} = Anthropic.translate_options(:chat, model, stop: ["STOP", "END"])
      assert Keyword.get(translated_opts, :stop_sequences) == ["STOP", "END"]
      assert Keyword.get(translated_opts, :stop) == nil
    end

    test "translate_options removes unsupported parameters" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      opts = [
        temperature: 0.7,
        presence_penalty: 0.1,
        frequency_penalty: 0.2,
        logprobs: true,
        response_format: %{type: "json"}
      ]

      {translated_opts, []} = Anthropic.translate_options(:chat, model, opts)

      # Should keep supported parameters
      assert Keyword.get(translated_opts, :temperature) == 0.7

      # Should remove unsupported parameters
      assert Keyword.get(translated_opts, :presence_penalty) == nil
      assert Keyword.get(translated_opts, :frequency_penalty) == nil
      assert Keyword.get(translated_opts, :logprobs) == nil
      assert Keyword.get(translated_opts, :response_format) == nil
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      body_with_usage = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {:ok, usage} = Anthropic.extract_usage(body_with_usage, model)
      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 20
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      body_without_usage = %{"content" => []}

      {:error, :no_usage_found} = Anthropic.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:error, :invalid_body} = Anthropic.extract_usage("invalid", model)
      {:error, :invalid_body} = Anthropic.extract_usage(nil, model)
      {:error, :invalid_body} = Anthropic.extract_usage(123, model)
    end
  end

  # Helper functions for Anthropic-specific fixtures

  describe "map-based parameter schemas (JSON Schema pass-through)" do
    test "tool with map parameter_schema serializes to Anthropic format correctly" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather information",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      schema = ReqLLM.Schema.to_anthropic_format(tool)

      # Verify Anthropic format
      assert schema["name"] == "get_weather"
      assert schema["description"] == "Get weather information"
      # The JSON schema should pass through unchanged
      assert schema["input_schema"] == json_schema
    end

    test "map-based schema works with Anthropic prepare_request pipeline" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"}
        },
        "required" => ["city"]
      }

      tool =
        ReqLLM.Tool.new!(
          name: "weather_lookup",
          description: "Look up weather",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, %{}} end
        )

      # Should successfully prepare request with map-based tool
      {:ok, request} =
        Anthropic.prepare_request(
          :chat,
          model,
          "What's the weather?",
          tools: [tool]
        )

      assert %Req.Request{} = request
      assert request.options[:tools] == [tool]
    end

    test "complex JSON Schema features preserved in Anthropic format" do
      complex_schema = %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "properties" => %{
                  "field" => %{"type" => "string"}
                }
              }
            ]
          }
        }
      }

      tool =
        ReqLLM.Tool.new!(
          name: "search",
          description: "Search",
          parameter_schema: complex_schema,
          callback: fn _ -> {:ok, []} end
        )

      schema = ReqLLM.Schema.to_anthropic_format(tool)

      # Complex schema should pass through unchanged
      assert schema["input_schema"] == complex_schema
      assert schema["input_schema"]["properties"]["filter"]["oneOf"]
    end
  end

  defp anthropic_format_json_fixture(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "msg_01XFDUDYJgAACzvnptvVoYEL"),
      "type" => "message",
      "role" => "assistant",
      "model" => Keyword.get(opts, :model, "claude-sonnet-4-5-20250929"),
      "content" => [
        %{
          "type" => "text",
          "text" => Keyword.get(opts, :content, "Hello! I'm doing well, thank you for asking.")
        }
      ],
      "stop_reason" => Keyword.get(opts, :stop_reason, "stop"),
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 12),
        "output_tokens" => Keyword.get(opts, :output_tokens, 15)
      }
    }
  end
end
