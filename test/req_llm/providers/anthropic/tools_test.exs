defmodule ReqLLM.Providers.Anthropic.ToolsTest do
  @moduledoc """
  Tests Anthropic client tool schemas, calls, and tool-result encoding.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

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

    test "encode_body round trips matched tool exchanges in assistant call order" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      base_context = ReqLLM.Context.new([ReqLLM.Context.user("Get weather and time")])

      assistant =
        ReqLLM.Context.assistant("",
          tool_calls: [
            {"get_weather", %{city: "Paris"}, id: "tool_1"},
            {"get_time", %{timezone: "Europe/Paris"}, id: "tool_2"}
          ],
          metadata: %{provider_native: %{request_id: "req_123"}}
        )

      results = [
        ReqLLM.Context.tool_result("tool_2", "get_time", "10:00 CEST"),
        ReqLLM.Context.tool_result("tool_1", "72°F and sunny")
      ]

      assert {:ok, context} =
               ReqLLM.Context.append_tool_exchange(base_context, assistant, results)

      mock_request = %Req.Request{
        options: [context: context, model: model.model, stream: false]
      }

      decoded = mock_request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      tool_result_blocks =
        decoded["messages"]
        |> List.last()
        |> Map.fetch!("content")

      assert Enum.map(tool_result_blocks, & &1["tool_use_id"]) == ["tool_1", "tool_2"]
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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_result_msg = List.last(decoded["messages"])
      [tool_result_block] = tool_result_msg["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tool_1"

      content_blocks = tool_result_block["content"]
      assert is_list(content_blocks)

      assert Enum.any?(content_blocks, fn block -> block["type"] == "image" end)
      assert Enum.any?(content_blocks, fn block -> block["type"] == "document" end)
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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # {:tool, name} should be normalized to %{type: "tool", name: "..."} for Anthropic
      assert decoded["tool_choice"] == %{"type" => "tool", "name" => "test_tool"}
    end

    test "encode_body emits is_error on tool_result when metadata contains is_error" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      error_tool_msg =
        ReqLLM.Context.tool_result_message(
          "get_weather",
          "tool_err",
          "ConnectionError: service unavailable",
          %{is_error: true}
        )

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather?"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "tool_err",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
              }
            ]
          ),
          error_tool_msg
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_result_msg = List.last(decoded["messages"])
      [tool_result_block] = tool_result_msg["content"]

      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tool_err"
      assert tool_result_block["is_error"] == true
    end

    test "encode_body keeps is_error true when ToolResult metadata conflicts" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      failing_tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Fails with conflicting metadata",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _args ->
            {:error,
             %ReqLLM.ToolResult{
               output: %{reason: "service unavailable"},
               content: [ContentPart.text("service unavailable")],
               metadata: %{is_error: false}
             }}
          end
        )

      tool_call =
        %ReqLLM.ToolCall{
          id: "tool_err_conflict",
          type: "function",
          function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
        }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather?"),
          ReqLLM.Context.assistant("", tool_calls: [tool_call])
        ])
        |> ReqLLM.Context.execute_and_append_tools([tool_call], [failing_tool])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_result_msg = List.last(decoded["messages"])
      [tool_result_block] = tool_result_msg["content"]

      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tool_err_conflict"
      assert tool_result_block["is_error"] == true
    end

    test "encode_body omits is_error on successful tool_result" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      ok_tool_msg =
        ReqLLM.Context.tool_result_message(
          "get_weather",
          "tool_ok",
          "22°C and sunny"
        )

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather?"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "tool_ok",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
              }
            ]
          ),
          ok_tool_msg
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_result_msg = List.last(decoded["messages"])
      [tool_result_block] = tool_result_msg["content"]

      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tool_ok"
      refute Map.has_key?(tool_result_block, "is_error")
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
               msg[:role] == "assistant" and
                 Enum.any?(List.wrap(msg[:content]), fn block ->
                   is_map(block) and
                     block[:type] == "tool_use" and
                     block[:name] == "get_time" and
                     block[:input] == %{"zone" => "UTC"}
                 end)
             end)

      assert Enum.any?(messages, fn msg ->
               msg[:role] == "user" and
                 Enum.any?(List.wrap(msg[:content]), fn block ->
                   is_map(block) and
                     block[:type] == "tool_result" and
                     block[:tool_use_id] == "call_123"
                 end)
             end)
    end

    test "encode_body sanitizes OpenAI-style tool call IDs for Anthropic" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Run a tool"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %{
                id: "functions.add:0",
                name: "add",
                arguments: %{"a" => 1, "b" => 2}
              }
            ]
          ),
          ReqLLM.Context.tool_result("functions.add:0", "3")
        ])

      mock_request = %Req.Request{
        options: [context: context, model: model.model, stream: false]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)
      messages = decoded["messages"]

      assistant_block =
        messages
        |> Enum.find(&(&1["role"] == "assistant"))
        |> Map.fetch!("content")
        |> Enum.find(&(&1["type"] == "tool_use"))

      tool_result_block =
        messages
        |> Enum.find(&(&1["role"] == "user" and is_list(&1["content"])))
        |> Map.fetch!("content")
        |> Enum.find(&(&1["type"] == "tool_result"))

      assert assistant_block["id"] == "functions_add_0"
      assert tool_result_block["tool_use_id"] == "functions_add_0"
    end

    test "encode_body handles tool calls with empty string arguments" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Take a screenshot"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "take_screenshot", arguments: ""}
              }
            ]
          ),
          ReqLLM.Context.tool_result("call_1", "screenshot.png")
        ])

      mock_request = %Req.Request{
        options: [context: context, model: model.model, stream: false]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)
      messages = decoded["messages"]

      tool_use_block =
        messages
        |> Enum.find(&(&1["role"] == "assistant"))
        |> Map.fetch!("content")
        |> Enum.find(&(&1["type"] == "tool_use"))

      assert tool_use_block["id"] == "call_1"
      assert tool_use_block["name"] == "take_screenshot"
      assert tool_use_block["input"] == %{}
    end

    test "encode_body rejects contexts ending with unresolved tool calls" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Run a tool"),
          ReqLLM.Context.assistant("",
            tool_calls: [
              %{
                id: "functions.add:0",
                name: "add",
                arguments: %{"a" => 1, "b" => 2}
              }
            ]
          )
        ])

      mock_request = %Req.Request{
        options: [context: context, model: model.model, stream: false]
      }

      assert_raise ReqLLM.Error.Invalid.Parameter,
                   ~r/Switch providers only after appending tool results/,
                   fn ->
                     Anthropic.encode_body(mock_request)
                   end
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

    test "includes anthropic-native tool fields from provider options" do
      tool =
        ReqLLM.Tool.new!(
          name: "deferred_tool",
          description: "A deferred tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name"]
          ],
          callback: fn _ -> {:ok, "result"} end,
          provider_options: [anthropic: [defer_loading: true]]
        )

      formatted = Anthropic.tool_to_anthropic_format(tool)

      assert formatted[:defer_loading] == true
      assert formatted[:name] == "deferred_tool"
    end
  end

  describe "encode_body with anthropic-native tool fields" do
    test "serializes defer_loading on tool definitions" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "deferred_tool",
          description: "A deferred tool",
          parameter_schema: [name: [type: :string, required: true]],
          callback: fn _ -> {:ok, "result"} end,
          provider_options: [anthropic: [defer_loading: true]]
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool]
        ]
      }

      updated_request = Anthropic.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["defer_loading"] == true
      assert encoded_tool["name"] == "deferred_tool"
    end
  end

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
end
