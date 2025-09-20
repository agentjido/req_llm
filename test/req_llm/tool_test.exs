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
        "special-chars",
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
      valid_names = ["valid_name", "CamelCase", "_underscore", "a1b2c3", "get_weather_info"]

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
        "kebab-case",
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
  end
end
