defmodule ReqLLM.SchemaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Schema
  alias ReqLLM.Tool

  describe "compile/1" do
    test "compiles valid keyword schemas" do
      schema = [name: [type: :string, required: true], age: [type: :pos_integer, default: 0]]
      assert {:ok, result} = Schema.compile(schema)
      assert result.schema == schema
      assert %NimbleOptions{} = result.compiled
    end

    test "compiles empty schema" do
      assert {:ok, result} = Schema.compile([])
      assert result.schema == []
      assert %NimbleOptions{} = result.compiled
    end

    test "returns error for invalid input types" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.compile("invalid")
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.compile(123)
    end

    test "returns error for malformed schema" do
      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.compile([:invalid])
      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.compile(name: :invalid)
    end
  end

  describe "to_json/1" do
    test "converts empty schema" do
      assert Schema.to_json([]) == %{"type" => "object", "properties" => %{}}
    end

    test "converts simple schema with required fields" do
      schema = [name: [type: :string, required: true, doc: "User name"]]

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["name"] == %{"type" => "string", "description" => "User name"}
      assert result["required"] == ["name"]
    end

    test "converts complex schema" do
      schema = [
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :pos_integer, doc: "User age"],
        tags: [type: {:list, :string}, doc: "User tags"],
        active: [type: :boolean, required: true]
      ]

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["name"]["type"] == "string"
      assert result["properties"]["age"]["type"] == "integer"
      assert result["properties"]["age"]["minimum"] == 1
      assert result["properties"]["tags"]["type"] == "array"
      assert result["properties"]["tags"]["items"]["type"] == "string"
      assert result["properties"]["active"]["type"] == "boolean"
      assert Enum.sort(result["required"]) == ["active", "name"]
    end

    test "handles lists with a map subtype" do
      tag_schema = {:map, [title: [type: :string, required: true], id: [type: :integer]]}

      schema = [
        tags: [type: {:list, tag_schema}]
      ]

      result = Schema.to_json(schema)

      assert result["properties"]["tags"]["type"] == "array"
      assert result["properties"]["tags"]["items"]["type"] == "object"
      assert result["properties"]["tags"]["items"]["properties"]["title"]["type"] == "string"
      assert result["properties"]["tags"]["items"]["properties"]["id"]["type"] == "integer"
      assert result["properties"]["tags"]["items"]["required"] == ["title"]
    end

    test "handles schema without required fields" do
      schema = [name: [type: :string, doc: "User name"], age: [type: :integer]]

      result = Schema.to_json(schema)

      refute Map.has_key?(result, "required")
    end

    test "reverses field order for required fields" do
      schema = [
        c: [type: :string, required: true],
        a: [type: :string, required: true],
        b: [type: :string, required: true]
      ]

      result = Schema.to_json(schema)

      assert result["required"] == ["c", "a", "b"]
    end
  end

  describe "nimble_type_to_json_schema/2" do
    test "converts basic types" do
      assert Schema.nimble_type_to_json_schema(:string, []) == %{"type" => "string"}
      assert Schema.nimble_type_to_json_schema(:integer, []) == %{"type" => "integer"}
      assert Schema.nimble_type_to_json_schema(:boolean, []) == %{"type" => "boolean"}
      assert Schema.nimble_type_to_json_schema(:float, []) == %{"type" => "number"}
      assert Schema.nimble_type_to_json_schema(:number, []) == %{"type" => "number"}
      assert Schema.nimble_type_to_json_schema(:map, []) == %{"type" => "object"}
      assert Schema.nimble_type_to_json_schema(:atom, []) == %{"type" => "string"}
    end

    test "converts constrained types" do
      assert Schema.nimble_type_to_json_schema(:pos_integer, []) == %{
               "type" => "integer",
               "minimum" => 1
             }
    end

    test "converts list types" do
      assert Schema.nimble_type_to_json_schema({:list, :string}, []) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :integer}, []) == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :boolean}, []) == %{
               "type" => "array",
               "items" => %{"type" => "boolean"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :float}, []) == %{
               "type" => "array",
               "items" => %{"type" => "number"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :number}, []) == %{
               "type" => "array",
               "items" => %{"type" => "number"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :pos_integer}, []) == %{
               "type" => "array",
               "items" => %{"type" => "integer", "minimum" => 1}
             }
    end

    test "converts nested list types recursively" do
      assert Schema.nimble_type_to_json_schema({:list, :atom}, []) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "converts map types" do
      assert Schema.nimble_type_to_json_schema({:map, :any}, []) == %{"type" => "object"}
      assert Schema.nimble_type_to_json_schema(:keyword_list, []) == %{"type" => "object"}
    end

    test "fallback for unknown types" do
      assert Schema.nimble_type_to_json_schema(:custom_type, []) == %{"type" => "string"}
      assert Schema.nimble_type_to_json_schema({:custom, :type}, []) == %{"type" => "string"}
    end

    test "adds description from doc option" do
      result = Schema.nimble_type_to_json_schema(:string, doc: "A text field")
      assert result == %{"type" => "string", "description" => "A text field"}

      result = Schema.nimble_type_to_json_schema({:list, :string}, doc: "List of strings")

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "description" => "List of strings"
             }
    end

    test "ignores nil doc option" do
      result = Schema.nimble_type_to_json_schema(:string, doc: nil)
      assert result == %{"type" => "string"}

      result = Schema.nimble_type_to_json_schema(:string, [])
      assert result == %{"type" => "string"}
    end

    test "converts :in type with list choices" do
      result = Schema.nimble_type_to_json_schema({:in, [:red, :green, :blue]}, [])
      assert result == %{"type" => "string", "enum" => [:red, :green, :blue]}

      result = Schema.nimble_type_to_json_schema({:in, ["small", "medium", "large"]}, [])
      assert result == %{"type" => "string", "enum" => ["small", "medium", "large"]}
    end

    test "converts :in type with range choices" do
      result = Schema.nimble_type_to_json_schema({:in, 1..10}, [])
      assert result == %{"type" => "integer", "minimum" => 1, "maximum" => 10}

      result = Schema.nimble_type_to_json_schema({:in, 0..255}, [])
      assert result == %{"type" => "integer", "minimum" => 0, "maximum" => 255}

      # Range with step
      result = Schema.nimble_type_to_json_schema({:in, 1..10//2}, [])
      assert result == %{"type" => "integer", "minimum" => 1, "maximum" => 10}
    end

    test "converts :in type with MapSet choices" do
      mapset = MapSet.new([:active, :passive, :disabled])
      result = Schema.nimble_type_to_json_schema({:in, mapset}, [])
      assert result["type"] == "string"
      # MapSet.to_list/1 doesn't guarantee order, so we check the elements are present
      assert Enum.sort(result["enum"]) == [:active, :disabled, :passive]
    end

    test "converts :in type with doc option" do
      result =
        Schema.nimble_type_to_json_schema({:in, [:red, :green, :blue]}, doc: "Color choice")

      assert result == %{
               "type" => "string",
               "enum" => [:red, :green, :blue],
               "description" => "Color choice"
             }
    end

    test "converts {:list, {:in, choices}} for arrays with enum constraints" do
      result = Schema.nimble_type_to_json_schema({:list, {:in, [:red, :green, :blue]}}, [])

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => [:red, :green, :blue]}
             }

      result = Schema.nimble_type_to_json_schema({:list, {:in, 1..5}}, [])

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
             }

      mapset = MapSet.new(["small", "medium", "large"])
      result = Schema.nimble_type_to_json_schema({:list, {:in, mapset}}, [])
      assert result["type"] == "array"
      assert result["items"]["type"] == "string"
      # MapSet.to_list/1 doesn't guarantee order, so we check the elements are present
      assert Enum.sort(result["items"]["enum"]) == ["large", "medium", "small"]
    end

    test "converts {:list, {:in, choices}} with doc option" do
      result =
        Schema.nimble_type_to_json_schema(
          {:list, {:in, [:urgent, :normal, :low]}},
          doc: "List of priority levels"
        )

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => [:urgent, :normal, :low]},
               "description" => "List of priority levels"
             }
    end
  end

  describe "to_anthropic_format/1" do
    setup do
      tool = %Tool{
        name: "search",
        description: "Search for items",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"],
          limit: [type: :pos_integer, doc: "Maximum results"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      {:ok, tool: tool}
    end

    test "formats tool with parameters", %{tool: tool} do
      result = Schema.to_anthropic_format(tool)

      assert result == %{
               "name" => "search",
               "description" => "Search for items",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "Search query"},
                   "limit" => %{
                     "type" => "integer",
                     "minimum" => 1,
                     "description" => "Maximum results"
                   }
                 },
                 "required" => ["query"],
                 "additionalProperties" => false
               }
             }
    end

    test "formats tool without parameters" do
      tool = %Tool{
        name: "ping",
        description: "Health check",
        parameter_schema: [],
        callback: fn _ -> {:ok, %{}} end
      }

      result = Schema.to_anthropic_format(tool)

      assert result == %{
               "name" => "ping",
               "description" => "Health check",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{}
               }
             }
    end

    test "formats tool with complex parameter types" do
      tool = %Tool{
        name: "complex_tool",
        description: "Tool with various parameter types",
        parameter_schema: [
          tags: [type: {:list, :string}, required: true, doc: "List of tags"],
          enabled: [type: :boolean, doc: "Whether enabled"],
          config: [type: :map, doc: "Configuration object"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      result = Schema.to_anthropic_format(tool)

      assert result["input_schema"]["properties"]["tags"]["type"] == "array"
      assert result["input_schema"]["properties"]["tags"]["items"]["type"] == "string"
      assert result["input_schema"]["properties"]["enabled"]["type"] == "boolean"
      assert result["input_schema"]["properties"]["config"]["type"] == "object"
      assert result["input_schema"]["required"] == ["tags"]
    end
  end

  # Consolidated tool format tests using table-driven approach
  describe "tool formatting" do
    setup do
      basic_tool = %Tool{
        name: "search",
        description: "Search for items",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"],
          limit: [type: :pos_integer, doc: "Maximum results"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      empty_tool = %Tool{
        name: "ping",
        description: "Health check",
        parameter_schema: [],
        callback: fn _ -> {:ok, %{}} end
      }

      complex_tool = %Tool{
        name: "complex_tool",
        description: "Tool with various parameter types",
        parameter_schema: [
          tags: [type: {:list, :string}, required: true, doc: "List of tags"],
          enabled: [type: :boolean, doc: "Whether enabled"],
          config: [type: :map, doc: "Configuration object"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      {:ok, basic_tool: basic_tool, empty_tool: empty_tool, complex_tool: complex_tool}
    end

    test "to_openai_format/1", %{
      basic_tool: tool,
      empty_tool: empty_tool,
      complex_tool: complex_tool
    } do
      # Test with parameters
      result = Schema.to_openai_format(tool)
      assert result["type"] == "function"
      assert result["function"]["name"] == "search"
      assert result["function"]["parameters"]["required"] == ["query"]

      # Test without parameters
      result = Schema.to_openai_format(empty_tool)
      assert result["function"]["parameters"]["properties"] == %{}
      refute Map.has_key?(result["function"]["parameters"], "required")

      # Test complex types
      result = Schema.to_openai_format(complex_tool)
      assert result["function"]["parameters"]["properties"]["tags"]["type"] == "array"
      assert result["function"]["parameters"]["properties"]["config"]["type"] == "object"
    end

    test "to_google_format/1", %{
      basic_tool: tool,
      empty_tool: empty_tool,
      complex_tool: complex_tool
    } do
      # Test with parameters
      result = Schema.to_google_format(tool)

      assert result == %{
               "name" => "search",
               "description" => "Search for items",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "Search query"},
                   "limit" => %{
                     "type" => "integer",
                     "minimum" => 1,
                     "description" => "Maximum results"
                   }
                 },
                 "required" => ["query"]
               }
             }

      # Test without parameters
      result = Schema.to_google_format(empty_tool)

      assert result == %{
               "name" => "ping",
               "description" => "Health check",
               "parameters" => %{"type" => "object", "properties" => %{}}
             }

      # Test complex types
      result = Schema.to_google_format(complex_tool)
      assert result["parameters"]["properties"]["tags"]["type"] == "array"
      assert result["parameters"]["properties"]["enabled"]["type"] == "boolean"
      assert result["parameters"]["required"] == ["tags"]
    end

    test "format consistency across providers", %{basic_tool: tool} do
      anthropic = Schema.to_anthropic_format(tool)
      openai = Schema.to_openai_format(tool)
      google = Schema.to_google_format(tool)

      # All should have same core schema structure
      anthropic_schema = anthropic["input_schema"]
      openai_schema = openai["function"]["parameters"]
      google_schema = google["parameters"]

      assert anthropic_schema == openai_schema

      assert anthropic_schema["additionalProperties"] == false
      assert openai_schema["additionalProperties"] == false
      refute Map.has_key?(google_schema, "additionalProperties")

      assert Map.delete(openai_schema, "additionalProperties") == google_schema
    end
  end

  describe ":in type integration tests" do
    test "converts schema with :in types in to_json/1" do
      schema = [
        color: [type: {:in, [:red, :green, :blue]}, required: true, doc: "Product color"],
        size: [type: {:in, 1..10}, doc: "Size from 1 to 10"],
        tags: [type: {:list, {:in, [:urgent, :normal, :low]}}, doc: "Priority tags"]
      ]

      result = Schema.to_json(schema)

      assert result["properties"]["color"] == %{
               "type" => "string",
               "enum" => [:red, :green, :blue],
               "description" => "Product color"
             }

      assert result["properties"]["size"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 10,
               "description" => "Size from 1 to 10"
             }

      assert result["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => [:urgent, :normal, :low]},
               "description" => "Priority tags"
             }

      assert result["required"] == ["color"]
    end

    test "validates data with :in type constraints" do
      schema = [
        status: [type: {:in, [:active, :inactive]}, required: true],
        priority: [type: {:in, 1..5}]
      ]

      # Valid data
      data = %{"status" => :active, "priority" => 3}
      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:status] == :active
      assert validated[:priority] == 3
    end
  end

  describe "nested list/map conversion scenarios" do
    test "converts nested list of maps" do
      schema = [
        users: [
          type: {:list, :map},
          doc: "List of user objects",
          properties: [
            name: [type: :string, required: true],
            email: [type: :string, required: true]
          ]
        ]
      ]

      result = Schema.to_json(schema)

      assert result["properties"]["users"]["type"] == "array"
      assert result["properties"]["users"]["items"]["type"] == "object"
    end

    test "converts deeply nested structures" do
      schema = [
        matrix: [type: {:list, {:list, :integer}}, doc: "2D array"],
        nested_maps: [type: {:list, {:map, :string}}, doc: "List of string maps"],
        custom_nested: [type: {:list, :atom}, doc: "List of atoms (fallback to string)"]
      ]

      result = Schema.to_json(schema)

      # Test nested lists
      matrix_prop = result["properties"]["matrix"]
      assert matrix_prop["type"] == "array"
      assert matrix_prop["items"]["type"] == "array"
      assert matrix_prop["items"]["items"]["type"] == "integer"

      # Test nested map types
      nested_maps_prop = result["properties"]["nested_maps"]
      assert nested_maps_prop["type"] == "array"
      assert nested_maps_prop["items"]["type"] == "object"

      # Test fallback in nested context
      custom_prop = result["properties"]["custom_nested"]
      assert custom_prop["type"] == "array"
      assert custom_prop["items"]["type"] == "string"
    end

    test "handles mixed complex types" do
      schema = [
        data: [
          type: :map,
          doc: "Complex data structure",
          properties: [
            tags: [type: {:list, :string}],
            metadata: [type: {:map, :any}],
            scores: [type: {:list, :float}]
          ]
        ]
      ]

      result = Schema.to_json(schema)
      data_prop = result["properties"]["data"]

      assert data_prop["type"] == "object"
      assert data_prop["description"] == "Complex data structure"
    end
  end

  describe "validate/2" do
    test "validates data against simple schema" do
      schema = [name: [type: :string, required: true], age: [type: :integer]]
      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:name] == "Alice"
      assert validated[:age] == 30
    end

    test "validates data with atom keys" do
      schema = [name: [type: :string, required: true]]
      data = %{name: "Bob"}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:name] == "Bob"
    end

    test "returns error for missing required field" do
      schema = [name: [type: :string, required: true], age: [type: :integer]]
      data = %{"age" => 30}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :schema_validation_failed}} =
               Schema.validate(data, schema)
    end

    test "returns error for invalid field type" do
      schema = [age: [type: :integer, required: true]]
      data = %{"age" => "not_an_integer"}

      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.validate(data, schema)
    end

    test "handles string keys that don't exist as atoms" do
      schema = [existing_field: [type: :string]]
      data = %{"non_existing_field" => "value"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :invalid_keys}} =
               Schema.validate(data, schema)
    end

    test "returns error for non-map data" do
      schema = [name: [type: :string]]

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate("not_a_map", schema)
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate([], schema)
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate(123, schema)
    end

    test "validates complex nested data" do
      schema = [
        user: [type: :string, required: true],
        preferences: [type: :map],
        tags: [type: {:list, :string}]
      ]

      data = %{
        "user" => "alice",
        "preferences" => %{theme: "dark"},
        "tags" => ["admin", "beta"]
      }

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:user] == "alice"
      assert validated[:preferences] == %{theme: "dark"}
      assert validated[:tags] == ["admin", "beta"]
    end

    test "validates empty data and schema" do
      assert {:ok, []} = Schema.validate(%{}, [])
    end

    test "handles validation with malformed schema" do
      schema = [:invalid_schema_format]
      data = %{"name" => "Alice"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :invalid_schema}} =
               Schema.validate(data, schema)
    end
  end

  describe "validate/2 with JSON Schema (JSV)" do
    test "validates simple object with valid data" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer", "minimum" => 1}
        },
        "required" => ["name"],
        "additionalProperties" => false
      }

      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == data
    end

    test "validates non-object root (array)" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      data = ["a", "b"]

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == ["a", "b"]
    end

    test "catches embedded JSON string instead of parsed map for property" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => ~s({"type":"string"})}
      }

      result = Schema.validate(%{}, schema)

      assert match?(
               {:error, %ReqLLM.Error.Validation.Error{tag: :invalid_json_schema}},
               result
             )
    end

    test "returns error for entire schema given as JSON string" do
      schema = ~s({"type":"object"})

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate(%{}, schema)
    end

    test "validation error for missing required field" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      data = %{"age" => 10}

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "required"
    end

    test "validation error for additionalProperties violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      data = %{"name" => "Alice", "extra" => 1}

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "extra"
    end

    test "validation error for type mismatch in array items" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      data = ["ok", 1]

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "/1"
    end

    test "validation error for enum violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"color" => %{"type" => "string", "enum" => ["red", "green"]}},
        "required" => ["color"]
      }

      data = %{"color" => "blue"}

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "enum" or reason =~ "blue"
    end

    test "validation error for nested object with multiple errors" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{"id" => %{"type" => "integer"}, "name" => %{"type" => "string"}},
            "required" => ["id", "name"],
            "additionalProperties" => false
          }
        },
        "required" => ["user"],
        "additionalProperties" => false
      }

      data = %{"user" => %{"id" => "bad", "extra" => 1}}

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "/user"
      assert reason =~ ", "
    end

    test "validation error for type mismatch at root (non-object root)" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      data = %{"not" => "an array"}

      assert {:error,
              %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed, reason: reason}} =
               Schema.validate(data, schema)

      assert reason =~ "array" or reason =~ "type"
    end

    test "validates complex nested structures" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "users" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "integer"},
                "name" => %{"type" => "string"}
              },
              "required" => ["id", "name"]
            }
          }
        },
        "required" => ["users"]
      }

      data = %{
        "users" => [
          %{"id" => 1, "name" => "Alice"},
          %{"id" => 2, "name" => "Bob"}
        ]
      }

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == data
    end

    test "validates data with minimum and maximum constraints" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 120}
        }
      }

      assert {:ok, _} = Schema.validate(%{"age" => 25}, schema)

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed}} =
               Schema.validate(%{"age" => 150}, schema)

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :json_schema_validation_failed}} =
               Schema.validate(%{"age" => -5}, schema)
    end

    test "preserves original data types without JSV casting (float to integer)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "temperature" => %{"type" => "integer"}
        }
      }

      data = %{"temperature" => 1.0}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == %{"temperature" => 1.0}
      assert validated["temperature"] === 1.0
    end

    test "preserves original data structure without JSV casting (nested)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "metrics" => %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "value" => %{"type" => "number"}
            }
          }
        }
      }

      data = %{"metrics" => %{"count" => 5.0, "value" => 3.14}}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == data
      assert validated["metrics"]["count"] === 5.0
      assert validated["metrics"]["value"] === 3.14
    end
  end

  describe "map pass-through support" do
    test "compile/1 with map returns wrapped schema with nil compiled" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"]
      }

      assert {:ok, result} = Schema.compile(json_schema)
      assert result.schema == json_schema
      assert result.compiled == nil
    end

    test "to_json/1 with map returns map unchanged" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      assert Schema.to_json(json_schema) == json_schema
    end

    test "equivalent keyword list and map produce compatible output" do
      keyword_schema = [
        location: [type: :string, required: true, doc: "City name"],
        units: [type: :string, doc: "Temperature units"]
      ]

      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"},
          "units" => %{"type" => "string", "description" => "Temperature units"}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      keyword_result = Schema.to_json(keyword_schema)
      map_result = Schema.to_json(json_schema)

      assert keyword_result == json_schema
      assert map_result == json_schema
    end

    test "provider format functions work with map parameter schemas" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"],
        "additionalProperties" => false
      }

      tool = %Tool{
        name: "search",
        description: "Search for items",
        parameter_schema: json_schema,
        callback: fn _ -> {:ok, %{}} end
      }

      # Test Anthropic format
      anthropic = Schema.to_anthropic_format(tool)
      assert anthropic["input_schema"] == json_schema

      # Test OpenAI format
      openai = Schema.to_openai_format(tool)
      assert openai["function"]["parameters"] == json_schema

      # Test Google format (strips additionalProperties)
      google = Schema.to_google_format(tool)
      assert google["parameters"] == Map.delete(json_schema, "additionalProperties")

      # Test Bedrock Converse format
      bedrock = Schema.to_bedrock_converse_format(tool)
      assert bedrock["toolSpec"]["inputSchema"]["json"] == json_schema
    end

    test "map with complex JSON Schema features" do
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
                  "operator" => %{"type" => "string", "enum" => ["eq", "ne", "gt", "lt"]},
                  "value" => %{"type" => "string"}
                },
                "required" => ["field", "operator", "value"]
              }
            ]
          },
          "timestamp" => %{
            "type" => "string",
            "format" => "date-time"
          }
        }
      }

      # Should pass through unchanged
      assert Schema.to_json(complex_schema) == complex_schema
      assert {:ok, result} = Schema.compile(complex_schema)
      assert result.schema == complex_schema
      assert result.compiled == nil
    end
  end
end
