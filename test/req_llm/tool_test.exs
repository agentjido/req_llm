defmodule ReqLLM.ToolTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Tool

  # Test fixtures
  defmodule TestModule do
    def simple_callback(args), do: {:ok, "Simple: #{inspect(args)}"}
    def error_callback(_args), do: {:error, "Intentional error"}
    def exception_callback(_args), do: raise("Boom!")

    def multi_arg_callback(extra1, extra2, args),
      do: {:ok, "Multi: #{extra1}, #{extra2}, #{inspect(args)}"}
  end

  describe "struct creation" do
    test "creates tool with all fields and defaults" do
      callback = fn _args -> {:ok, "result"} end

      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        parameter_schema: [location: [type: :string]],
        callback: callback
      }

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert tool.parameter_schema == [location: [type: :string]]
      assert tool.callback == callback
      assert tool.compiled == nil
    end
  end

  describe "new/1" do
    test "creates tool with minimal params" do
      params = [
        name: "minimal_tool",
        description: "Minimal tool",
        callback: fn _args -> {:ok, "minimal"} end
      ]

      {:ok, tool} = Tool.new(params)

      assert tool.name == "minimal_tool"
      assert tool.description == "Minimal tool"
      assert tool.parameter_schema == []
      assert tool.compiled == nil
      assert is_function(tool.callback, 1)
    end

    test "creates tool with full params and compiles schema" do
      params = [
        name: "weather_tool",
        description: "Get weather information",
        parameter_schema: [
          location: [type: :string, required: true],
          units: [type: :string, default: "celsius"]
        ],
        callback: fn args -> {:ok, "Weather: #{args[:location]}"} end
      ]

      {:ok, tool} = Tool.new(params)

      assert tool.name == "weather_tool"
      assert tool.description == "Get weather information"
      assert Keyword.keyword?(tool.parameter_schema)
      assert tool.compiled != nil
      assert is_function(tool.callback, 1)
    end

    test "supports various MFA callback formats" do
      # MFA without extra args
      {:ok, tool1} =
        Tool.new(
          name: "mfa_tool",
          description: "MFA test",
          callback: {TestModule, :simple_callback}
        )

      assert tool1.callback == {TestModule, :simple_callback}

      # MFA with extra args
      {:ok, tool2} =
        Tool.new(
          name: "mfa_args_tool",
          description: "MFA with args",
          callback: {TestModule, :multi_arg_callback, ["arg1", "arg2"]}
        )

      assert tool2.callback == {TestModule, :multi_arg_callback, ["arg1", "arg2"]}
    end

    test "validates tool name format" do
      # Invalid names
      invalid_names = [
        "invalid name with spaces",
        "123starts_with_number",
        "special@chars",
        "emoji😊",
        "",
        # > 64 chars
        String.duplicate("a", 65)
      ]

      for name <- invalid_names do
        params = [name: name, description: "Test", callback: fn _ -> {:ok, "ok"} end]
        assert {:error, _} = Tool.new(params)
      end

      # Valid names
      valid_names = [
        "valid_name",
        "CamelCase",
        "_underscore",
        "a1b2c3",
        "get_weather_info",
        "kebab-case",
        "notion-get-users"
      ]

      for name <- valid_names do
        params = [name: name, description: "Test", callback: fn _ -> {:ok, "ok"} end]
        assert {:ok, _} = Tool.new(params)
      end
    end

    test "validates callback format" do
      base_params = [name: "test", description: "Test"]

      # Invalid callbacks
      invalid_callbacks = [
        "string",
        123,
        {NotAModule, :function},
        {TestModule, :nonexistent},
        {TestModule, :simple_callback, "not_a_list"}
      ]

      for callback <- invalid_callbacks do
        params = base_params ++ [callback: callback]
        assert {:error, _} = Tool.new(params)
      end
    end

    test "validates required fields" do
      assert {:error, _} = Tool.new([])
      assert {:error, _} = Tool.new(name: "test")
      assert {:error, _} = Tool.new(description: "test")
      assert {:error, _} = Tool.new(name: "test", description: "test")
    end

    test "validates non-keyword input" do
      assert {:error, error} = Tool.new("not a keyword list")
      assert Exception.message(error) =~ "keyword list"

      assert {:error, error} = Tool.new(%{name: "test"})
      assert Exception.message(error) =~ "keyword list"
    end
  end

  describe "new!/1" do
    test "returns tool on success" do
      params = [
        name: "bang_tool",
        description: "Success test",
        callback: fn _ -> {:ok, "ok"} end
      ]

      tool = Tool.new!(params)
      assert %Tool{} = tool
      assert tool.name == "bang_tool"
    end

    test "raises on error" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Tool.new!(name: "invalid name", description: "Test", callback: fn _ -> {:ok, "ok"} end)
      end
    end
  end

  describe "execute/2" do
    setup do
      {:ok, simple_tool} =
        Tool.new(
          name: "simple",
          description: "Simple tool",
          callback: {TestModule, :simple_callback}
        )

      {:ok, parameterized_tool} =
        Tool.new(
          name: "parameterized",
          description: "Tool with params",
          parameter_schema: [
            required_field: [type: :string, required: true],
            optional_field: [type: :integer, default: 42]
          ],
          callback: fn args -> {:ok, "Got: #{inspect(args)}"} end
        )

      %{simple_tool: simple_tool, parameterized_tool: parameterized_tool}
    end

    test "happy path - executes tool successfully", %{simple_tool: tool} do
      assert {:ok, "Simple: %{name: \"John\"}"} = Tool.execute(tool, %{name: "John"})
    end

    test "invalid parameter schema validation", %{parameterized_tool: tool} do
      assert {:error, %ReqLLM.Error.Validation.Error{}} = Tool.execute(tool, %{})

      assert {:error, %ReqLLM.Error.Validation.Error{}} =
               Tool.execute(tool, %{required_field: 123})
    end

    test "callback crash path" do
      {:ok, exception_tool} =
        Tool.new(
          name: "exception_tool",
          description: "Exception test",
          callback: {TestModule, :exception_callback}
        )

      assert {:error, %ReqLLM.Error.Unknown.Unknown{}} = Tool.execute(exception_tool, %{})
    end

    test "validates input type" do
      {:ok, tool} =
        Tool.new(
          name: "type_test",
          description: "Type validation",
          callback: fn _ -> {:ok, "ok"} end
        )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Tool.execute(tool, "not a map")
    end
  end

  describe "to_schema/2" do
    setup do
      {:ok, simple_tool} =
        Tool.new(
          name: "simple_tool",
          description: "Simple description",
          parameter_schema: [],
          callback: fn _ -> {:ok, "ok"} end
        )

      {:ok, complex_tool} =
        Tool.new(
          name: "complex_tool",
          description: "Complex with parameters",
          parameter_schema: [
            location: [type: :string, required: true, doc: "City name"],
            units: [type: :string, default: "celsius", doc: "Temperature units"],
            days: [type: :pos_integer, default: 7]
          ],
          callback: fn _ -> {:ok, "weather"} end
        )

      %{simple_tool: simple_tool, complex_tool: complex_tool}
    end

    test "generates anthropic schema", %{simple_tool: tool} do
      schema = Tool.to_schema(tool, :anthropic)

      assert schema["name"] == "simple_tool"
      assert schema["description"] == "Simple description"
      assert is_map(schema["input_schema"])

      # Anthropic format doesn't have these fields
      refute Map.has_key?(schema, "type")
      refute Map.has_key?(schema, "function")
    end

    test "generates correct schema format", %{complex_tool: tool} do
      schema = Tool.to_schema(tool, :anthropic)
      input_schema = schema["input_schema"]

      assert input_schema["type"] == "object"
      assert is_map(input_schema["properties"])
    end

    test "raises for unknown provider", %{simple_tool: tool} do
      assert_raise ArgumentError, ~r/Unknown provider/, fn ->
        Tool.to_schema(tool, :unknown_provider)
      end
    end
  end

  describe "to_json_schema/1 (backward compatibility)" do
    test "defaults to openai format" do
      {:ok, tool} =
        Tool.new(
          name: "compat_tool",
          description: "Backward compatibility",
          parameter_schema: [value: [type: :integer, required: true]],
          callback: fn _ -> {:ok, 42} end
        )

      compat_schema = Tool.to_json_schema(tool)
      openai_schema = Tool.to_schema(tool, :openai)

      assert compat_schema == openai_schema
    end
  end

  describe "valid_name?/1" do
    test "validates tool names" do
      # Valid names
      valid_names = [
        "simple_name",
        "CamelCase",
        "_underscore_start",
        "name_with_123",
        "a",
        "get_weather_info_v2",
        "kebab-case",
        "notion-get-users",
        "get-response",
        # exactly 64 chars
        String.duplicate("a", 64)
      ]

      for name <- valid_names do
        assert Tool.valid_name?(name), "#{name} should be valid"
      end

      # Invalid names
      invalid_names = [
        "name with spaces",
        "123starts_with_number",
        "-starts-with-hyphen",
        "ends-with-hyphen-",
        "special@chars",
        "emoji😊name",
        "",
        # > 64 chars
        String.duplicate("a", 65),
        nil,
        :atom,
        123
      ]

      for name <- invalid_names do
        refute Tool.valid_name?(name), "#{inspect(name)} should be invalid"
      end
    end

    test "allows hyphenated tool names for MCP server compatibility" do
      # These are real-world examples from MCP servers like Notion
      mcp_tool_names = [
        "notion-get-users",
        "notion-create-page",
        "slack-send-message",
        "github-create-issue",
        "get-response"
      ]

      for name <- mcp_tool_names do
        assert Tool.valid_name?(name), "MCP tool name #{name} should be valid"

        {:ok, tool} =
          Tool.new(
            name: name,
            description: "MCP tool",
            callback: fn _ -> {:ok, "result"} end
          )

        assert tool.name == name
      end
    end
  end

  describe "map-based parameter schemas (JSON Schema pass-through)" do
    test "creates tool with map parameter_schema" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"]
      }

      {:ok, tool} =
        Tool.new(
          name: "get_weather",
          description: "Get weather information",
          parameter_schema: json_schema,
          callback: fn _args -> {:ok, "sunny"} end
        )

      assert tool.parameter_schema == json_schema
      assert tool.compiled == nil
    end

    test "executes tool with map parameter_schema (validation skipped)" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"}
        },
        "required" => ["query"]
      }

      {:ok, tool} =
        Tool.new(
          name: "search",
          description: "Search for items",
          parameter_schema: json_schema,
          callback: fn args ->
            # Handle both string and atom keys
            query = args["query"] || args[:query]
            {:ok, "Found: #{query}"}
          end
        )

      # Should execute successfully without NimbleOptions validation
      {:ok, result} = Tool.execute(tool, %{"query" => "test"})
      assert result == "Found: test"

      # Should also work with atom keys since validation is skipped
      {:ok, result} = Tool.execute(tool, %{query: "test2"})
      assert result == "Found: test2"
    end

    test "tool with map schema converts to provider formats" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "integer"}
        },
        "required" => ["value"]
      }

      {:ok, tool} =
        Tool.new(
          name: "process",
          description: "Process value",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, 42} end
        )

      # Test all provider formats
      anthropic = Tool.to_schema(tool, :anthropic)
      assert anthropic["input_schema"] == json_schema

      openai = Tool.to_schema(tool, :openai)
      assert openai["function"]["parameters"] == json_schema

      google = Tool.to_schema(tool, :google)
      # Google format strips additionalProperties
      assert Map.has_key?(google, "parameters")

      bedrock = Tool.to_schema(tool, :amazon_bedrock_converse)
      assert bedrock["toolSpec"]["inputSchema"]["json"] == json_schema
    end

    test "rejects invalid parameter_schema types" do
      invalid_schemas = [
        "string",
        123,
        :atom,
        {:tuple, "value"}
      ]

      for invalid <- invalid_schemas do
        {:error, error} =
          Tool.new(
            name: "invalid_tool",
            description: "Test",
            parameter_schema: invalid,
            callback: fn _ -> {:ok, nil} end
          )

        assert %ReqLLM.Error.Invalid.Parameter{} = error
        assert error.parameter =~ "Invalid parameter_schema"
      end
    end

    test "supports empty map schema" do
      {:ok, tool} =
        Tool.new(
          name: "no_params",
          description: "Tool with no parameters",
          parameter_schema: %{},
          callback: fn _ -> {:ok, "done"} end
        )

      assert tool.parameter_schema == %{}
      assert tool.compiled == nil

      {:ok, result} = Tool.execute(tool, %{})
      assert result == "done"
    end

    test "complex JSON Schema with advanced features" do
      complex_schema = %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "properties" => %{
                  "field" => %{"type" => "string"},
                  "operator" => %{"type" => "string", "enum" => ["eq", "ne"]},
                  "value" => %{}
                },
                "required" => ["field", "operator", "value"]
              }
            ]
          },
          "timestamp" => %{
            "type" => "string",
            "format" => "date-time"
          }
        },
        "additionalProperties" => false
      }

      {:ok, tool} =
        Tool.new(
          name: "advanced_search",
          description: "Search with complex filters",
          parameter_schema: complex_schema,
          callback: fn _ -> {:ok, []} end
        )

      assert tool.parameter_schema == complex_schema

      # Should pass through to providers unchanged
      anthropic = Tool.to_schema(tool, :anthropic)
      assert anthropic["input_schema"] == complex_schema
    end
  end

  describe "Inspect protocol" do
    test "handles NimbleOptions parameter schema (list)" do
      {:ok, tool} =
        Tool.new(
          name: "nimble_tool",
          description: "Tool with NimbleOptions schema",
          parameter_schema: [
            location: [type: :string, required: true],
            units: [type: :string]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      inspected = inspect(tool)
      assert inspected =~ "#Tool<\"nimble_tool\""
      assert inspected =~ "2 params>"
    end

    test "handles JSON Schema parameter schema (map)" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"},
          "units" => %{"type" => "string"}
        },
        "required" => ["location"]
      }

      {:ok, tool} =
        Tool.new(
          name: "json_tool",
          description: "Tool with JSON Schema",
          parameter_schema: json_schema,
          callback: fn _ -> {:ok, "result"} end
        )

      inspected = inspect(tool)
      assert inspected =~ "#Tool<\"json_tool\""
      assert inspected =~ "2 params (JSON Schema)>"
    end

    test "handles empty NimbleOptions schema" do
      {:ok, tool} =
        Tool.new(
          name: "no_params_tool",
          description: "Tool without params",
          parameter_schema: [],
          callback: fn _ -> {:ok, "result"} end
        )

      inspected = inspect(tool)
      assert inspected =~ "#Tool<\"no_params_tool\""
      assert inspected =~ "no params>"
    end

    test "handles empty JSON Schema" do
      {:ok, tool} =
        Tool.new(
          name: "empty_json_tool",
          description: "Tool with empty JSON Schema",
          parameter_schema: %{
            "type" => "object",
            "properties" => %{}
          },
          callback: fn _ -> {:ok, "result"} end
        )

      inspected = inspect(tool)
      assert inspected =~ "#Tool<\"empty_json_tool\""
      assert inspected =~ "no params (JSON Schema)>"
    end
  end
end
