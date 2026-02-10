defmodule ReqLLM.Providers.AnthropicTest do
  @moduledoc """
  Provider-level tests for Anthropic implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic

  alias ReqLLM.Message.ContentPart
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

    test "encode_body preserves multimodal tool_result content blocks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      image_part = ContentPart.image(<<137, 80, 78, 71>>, "image/png")
      file_part = ContentPart.file("doc", "note.txt", "text/plain")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Use the tool."),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "tool_1",
                type: "function",
                function: %{name: "get_asset", arguments: ~s({"id":"1"})}
              }
            ]
          ),
          ReqLLM.Context.tool_result("tool_1", [image_part, file_part])
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

      tool_result_msg = List.last(decoded["messages"])
      [tool_result_block] = tool_result_msg["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tool_1"

      content_blocks = tool_result_block["content"]
      assert is_list(content_blocks)

      assert Enum.any?(content_blocks, fn block -> block["type"] == "image" end)
      assert Enum.any?(content_blocks, fn block -> block["type"] == "document" end)
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

  describe "tool_to_anthropic_format/1 strict mode" do
    test "includes strict: true when tool has strict enabled" do
      tool =
        ReqLLM.Tool.new!(
          name: "strict_tool",
          description: "A strict tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name"]
          ],
          callback: fn _ -> {:ok, "result"} end,
          strict: true
        )

      formatted = Anthropic.tool_to_anthropic_format(tool)

      assert formatted[:strict] == true
      assert formatted[:name] == "strict_tool"
      assert formatted[:description] == "A strict tool"
      assert is_map(formatted[:input_schema])
    end

    test "does not include strict key when tool has strict disabled" do
      tool =
        ReqLLM.Tool.new!(
          name: "non_strict_tool",
          description: "A non-strict tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name"]
          ],
          callback: fn _ -> {:ok, "result"} end,
          strict: false
        )

      formatted = Anthropic.tool_to_anthropic_format(tool)

      refute Map.has_key?(formatted, :strict)
      assert formatted[:name] == "non_strict_tool"
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

  describe "web search tool" do
    test "encode_body with web_search configuration" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              max_uses: 5,
              allowed_domains: ["wikipedia.org", "britannica.com"]
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["name"] == "web_search"
      assert web_search_tool["max_uses"] == 5
      assert web_search_tool["allowed_domains"] == ["wikipedia.org", "britannica.com"]
    end

    test "encode_body with web_search and user location" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      user_location = %{
        type: "approximate",
        city: "San Francisco",
        region: "California",
        country: "US",
        timezone: "America/Los_Angeles"
      }

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              max_uses: 3,
              user_location: user_location
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["max_uses"] == 3
      # After JSON encoding/decoding, keys become strings
      assert web_search_tool["user_location"]["type"] == "approximate"
      assert web_search_tool["user_location"]["city"] == "San Francisco"
      assert web_search_tool["user_location"]["region"] == "California"
      assert web_search_tool["user_location"]["country"] == "US"
      assert web_search_tool["user_location"]["timezone"] == "America/Los_Angeles"
    end

    test "encode_body with web_search and blocked_domains" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [
            web_search: %{
              blocked_domains: ["untrustedsource.com"]
            }
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [web_search_tool] = decoded["tools"]
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["blocked_domains"] == ["untrustedsource.com"]
      refute Map.has_key?(web_search_tool, "max_uses")
    end

    test "encode_body with both regular tools and web_search" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather for a location",
          parameter_schema: [
            location: [type: :string, required: true]
          ],
          callback: fn _ -> {:ok, "Sunny"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          provider_options: [
            web_search: %{max_uses: 5}
          ]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 2

      [regular_tool, web_search_tool] = decoded["tools"]
      assert regular_tool["name"] == "get_weather"
      assert web_search_tool["type"] == "web_search_20250305"
      assert web_search_tool["name"] == "web_search"
      assert web_search_tool["max_uses"] == 5
    end
  end

  describe "map_reasoning_effort_to_budget/1" do
    test "translate_options maps reasoning_effort to thinking budget_tokens" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      test_cases = [
        {:none, nil},
        {:minimal, 512},
        {:low, 1_024},
        {:medium, 2_048},
        {:high, 4_096},
        {:xhigh, 8_192}
      ]

      for {effort, expected_budget} <- test_cases do
        opts = [reasoning_effort: effort]
        {translated_opts, _warnings} = Anthropic.translate_options(:chat, model, opts)

        thinking = Keyword.get(translated_opts, :thinking)

        if expected_budget == nil do
          assert thinking == nil,
                 "Expected reasoning_effort #{inspect(effort)} to not set thinking option"
        else
          assert thinking != nil,
                 "Expected reasoning_effort #{inspect(effort)} to set thinking option"

          assert thinking.budget_tokens == expected_budget,
                 "Expected reasoning_effort #{inspect(effort)} to map to budget #{expected_budget}"
        end
      end
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

  describe "thinking blocks (reasoning details)" do
    test "decode_response extracts thinking blocks into reasoning_details" do
      response_with_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{
            "type" => "thinking",
            "thinking" => "Let me analyze this step by step...",
            "signature" => "EqQBtest123"
          },
          %{"type" => "text", "text" => "The answer is 42."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(response_with_thinking, model)

      assert response.message != nil
      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1

      [detail] = response.message.reasoning_details
      assert detail.text == "Let me analyze this step by step..."
      assert detail.signature == "EqQBtest123"
      assert detail.encrypted? == true
      assert detail.provider == :anthropic
      assert detail.format == "anthropic-thinking-v1"
      assert detail.index == 0
      assert detail.provider_data == %{"type" => "thinking"}
    end

    test "decode_response handles response without thinking blocks" do
      response_without_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{"type" => "text", "text" => "Just a regular response."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(response_without_thinking, model)

      assert response.message != nil
      assert response.message.reasoning_details == nil
    end

    test "decode_response handles multiple thinking blocks" do
      response_with_multiple_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{"type" => "thinking", "thinking" => "First thought...", "signature" => "sig1"},
          %{"type" => "thinking", "thinking" => "Second thought...", "signature" => "sig2"},
          %{"type" => "text", "text" => "My conclusion."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          response_with_multiple_thinking,
          model
        )

      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert first.text == "First thought..."
      assert first.index == 0
      assert second.text == "Second thought..."
      assert second.index == 1
    end

    test "encode_message includes thinking blocks for assistant with reasoning_details" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "My thinking process...",
        signature: "EqQBsignature123",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "The answer is 42."}],
        reasoning_details: [reasoning_detail],
        metadata: %{}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What is the meaning of life?"),
          assistant_message
        ])

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      messages = encoded[:messages]

      assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
      assert assistant_msg != nil
      assert is_list(assistant_msg[:content])

      content_blocks = assistant_msg[:content]
      thinking_block = Enum.find(content_blocks, fn b -> b[:type] == "thinking" end)
      text_block = Enum.find(content_blocks, fn b -> b[:type] == "text" end)

      assert thinking_block != nil
      assert thinking_block[:thinking] == "My thinking process..."
      assert thinking_block[:signature] == "EqQBsignature123"

      assert text_block != nil
      assert text_block[:text] == "The answer is 42."

      thinking_index = Enum.find_index(content_blocks, fn b -> b[:type] == "thinking" end)
      text_index = Enum.find_index(content_blocks, fn b -> b[:type] == "text" end)
      assert thinking_index < text_index
    end

    test "encode_message skips non-Anthropic reasoning details with warning" do
      import ExUnit.CaptureLog

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      non_anthropic_detail = %ReqLLM.Message.ReasoningDetails{
        text: "OpenAI reasoning...",
        signature: nil,
        encrypted?: false,
        provider: :openai,
        format: "openai-reasoning-v1",
        index: 0,
        provider_data: %{}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Response text."}],
        reasoning_details: [non_anthropic_detail],
        metadata: %{}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Question?"),
          assistant_message
        ])

      log =
        capture_log(fn ->
          encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
          messages = encoded[:messages]
          assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
          content_blocks = assistant_msg[:content]

          thinking_blocks =
            Enum.filter(content_blocks, fn b ->
              is_map(b) and b[:type] == "thinking"
            end)

          assert thinking_blocks == []
        end)

      assert log =~ "Skipping non-Anthropic reasoning detail"
      assert log =~ ":openai"
    end

    test "encode_message with reasoning_details and tool_calls preserves order" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me think about which tool to use...",
        signature: "sig123",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      tool_call = %ReqLLM.ToolCall{
        id: "call_123",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "I'll check the weather."}],
        tool_calls: [tool_call],
        reasoning_details: [reasoning_detail],
        metadata: %{}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather in NYC?"),
          assistant_message
        ])

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      messages = encoded[:messages]

      assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
      content_blocks = assistant_msg[:content]

      type_order = Enum.map(content_blocks, fn b -> b[:type] end)
      assert type_order == ["thinking", "text", "tool_use"]
    end
  end

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Providers.Anthropic.ResponseBuilder

    test "extracts reasoning_details from thinking chunks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        encrypted?: false,
        provider_data: %{"type" => "thinking"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Let me analyze this step by step", thinking_meta),
        ReqLLM.StreamChunk.thinking("First, consider the constraints", thinking_meta),
        ReqLLM.StreamChunk.text("The answer is 42.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = first
      assert first.text == "Let me analyze this step by step"
      assert first.provider == :anthropic
      assert first.format == "anthropic-thinking-v1"
      assert first.index == 0

      assert second.text == "First, consider the constraints"
      assert second.index == 1
    end

    test "returns nil reasoning_details when no thinking chunks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Just a simple response.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details == nil
    end

    test "preserves signature from thinking chunk metadata" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        %ReqLLM.StreamChunk{
          type: :thinking,
          text: "Deep thought",
          metadata: %{signature: "sig_abc123"}
        },
        ReqLLM.StreamChunk.text("Response")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [detail] = response.message.reasoning_details
      assert detail.signature == "sig_abc123"
    end

    test "attaches reasoning_details to context messages" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Extended reasoning here"),
        ReqLLM.StreamChunk.text("Final answer")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [context_msg] = response.context.messages
      assert context_msg.reasoning_details != nil
      assert length(context_msg.reasoning_details) == 1
      assert hd(context_msg.reasoning_details).text == "Extended reasoning here"
    end

    test "ensures non-empty content when tool calls present" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Planning tool use"),
        %ReqLLM.StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{"location" => "NYC"},
          metadata: %{id: "call_123", index: 0}
        }
      ]

      metadata = %{finish_reason: :tool_calls}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.content != []
      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1
    end
  end

  describe "prepare_request(:object) - schema constraint stripping" do
    test "strips minimum constraint from pos_integer schema in json_schema mode" do
      {:ok, schema} =
        ReqLLM.Schema.compile(
          count: [type: :pos_integer, required: true, doc: "A positive count"]
        )

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["count"], "minimum")
      assert output_format.schema["properties"]["count"]["type"] == "integer"
    end

    test "strips maximum constraint from integer schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "rating" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["rating"], "minimum")
      refute Map.has_key?(output_format.schema["properties"]["rating"], "maximum")
    end

    test "strips minLength and maxLength from string schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)

      refute Map.has_key?(output_format.schema["properties"]["name"], "minLength")
      refute Map.has_key?(output_format.schema["properties"]["name"], "maxLength")
    end

    test "recursively strips constraints from nested schemas" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{
              "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
              "name" => %{"type" => "string", "minLength" => 1}
            }
          },
          "scores" => %{
            "type" => "array",
            "items" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
          }
        }
      }

      compiled_schema = %{schema: schema}

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: compiled_schema
        )

      provider_opts = request.options[:provider_options]
      output_format = Keyword.get(provider_opts, :output_format)
      props = output_format.schema["properties"]

      refute Map.has_key?(props["user"]["properties"]["age"], "minimum")
      refute Map.has_key?(props["user"]["properties"]["age"], "maximum")
      refute Map.has_key?(props["user"]["properties"]["name"], "minLength")
      refute Map.has_key?(props["scores"]["items"], "minimum")
      refute Map.has_key?(props["scores"]["items"], "maximum")
    end

    test "strips constraints in tool_strict mode" do
      {:ok, schema} =
        ReqLLM.Schema.compile(
          value: [type: :pos_integer, required: true, doc: "A positive value"]
        )

      tool =
        ReqLLM.Tool.new!(
          name: "other_tool",
          description: "Another tool",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, "done"} end
        )

      {:ok, request} =
        Anthropic.prepare_request(:object, "anthropic:claude-sonnet-4-5-20250929", "Generate",
          compiled_schema: schema,
          tools: [tool]
        )

      tools = request.options[:tools]
      structured_tool = Enum.find(tools, fn t -> t.name == "structured_output" end)

      refute Map.has_key?(structured_tool.parameter_schema["properties"]["value"], "minimum")
    end
  end
end
