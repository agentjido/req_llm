defmodule ReqLLM.Tool.ZoiTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Schema
  alias ReqLLM.Tool

  defmodule TestCallbacks do
    def simple_callback(args), do: {:ok, "Received: #{inspect(args)}"}

    def weather_callback(args) do
      location = args["location"] || args[:location]
      units = args["units"] || args[:units] || "celsius"
      {:ok, %{location: location, temperature: 72, units: units}}
    end

    def nested_callback(args) do
      user = args["user"] || args[:user]
      {:ok, "User: #{inspect(user)}"}
    end
  end

  describe "tool with Zoi parameter schema" do
    test "creates tool with simple Zoi schema" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create a user",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      assert tool.name == "create_user"
      assert tool.description == "Create a user"
      assert tool.parameter_schema == schema
      assert tool.compiled == nil
    end

    test "creates tool with nested Zoi schema" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              name: Zoi.string(),
              email: Zoi.string()
            }),
          metadata:
            Zoi.object(%{
              tags: Zoi.array(Zoi.string())
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "create_profile",
          description: "Create user profile",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      assert tool.parameter_schema == schema
      assert tool.compiled == nil
    end

    test "creates tool with array Zoi schema" do
      schema =
        Zoi.object(%{
          items: Zoi.array(Zoi.string()),
          count: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "process_items",
          description: "Process a list of items",
          parameter_schema: schema,
          callback: fn _args -> {:ok, "processed"} end
        )

      assert is_struct(tool.parameter_schema)
    end

    test "creates tool with optional fields in Zoi schema" do
      schema =
        Zoi.object(%{
          required_field: Zoi.string(),
          optional_field: Zoi.optional(Zoi.string())
        })

      {:ok, tool} =
        Tool.new(
          name: "flexible_tool",
          description: "Tool with optional params",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      assert tool.parameter_schema == schema
    end

    test "creates tool with enum Zoi schema" do
      schema =
        Zoi.object(%{
          status: Zoi.enum(["active", "inactive", "pending"]),
          priority: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "set_status",
          description: "Set item status",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      assert tool.parameter_schema == schema
    end
  end

  describe "generates correct JSON Schema for OpenAI format" do
    test "simple Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          location: Zoi.string(),
          units: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "get_weather",
          description: "Get weather for location",
          parameter_schema: schema,
          callback: &TestCallbacks.weather_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)

      assert openai_schema["type"] == "function"
      assert openai_schema["function"]["name"] == "get_weather"
      assert openai_schema["function"]["description"] == "Get weather for location"

      parameters = openai_schema["function"]["parameters"]
      assert parameters["type"] == "object"
      assert parameters["properties"]["location"]["type"] == "string"
      assert parameters["properties"]["units"]["type"] == "string"
    end

    test "nested Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              name: Zoi.string(),
              email: Zoi.string()
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create user",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["type"] == "object"
      assert parameters["properties"]["user"]["type"] == "object"
      assert parameters["properties"]["user"]["properties"]["name"]["type"] == "string"
      assert parameters["properties"]["user"]["properties"]["email"]["type"] == "string"
    end

    test "array Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          tags: Zoi.array(Zoi.string())
        })

      {:ok, tool} =
        Tool.new(
          name: "add_tags",
          description: "Add tags",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["properties"]["tags"]["type"] == "array"
      assert parameters["properties"]["tags"]["items"]["type"] == "string"
    end

    test "enum Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          status: Zoi.enum(["active", "inactive", "pending"])
        })

      {:ok, tool} =
        Tool.new(
          name: "set_status",
          description: "Set status",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["properties"]["status"]["enum"] == ["active", "inactive", "pending"]
    end

    test "number constraints in Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          percentage: Zoi.number() |> Zoi.min(0) |> Zoi.max(100)
        })

      {:ok, tool} =
        Tool.new(
          name: "set_percentage",
          description: "Set percentage",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["properties"]["percentage"]["type"] == "number"
      assert parameters["properties"]["percentage"]["minimum"] == 0
      assert parameters["properties"]["percentage"]["maximum"] == 100
    end

    test "string constraints in Zoi schema to OpenAI format" do
      schema =
        Zoi.object(%{
          username: Zoi.string() |> Zoi.min(3) |> Zoi.max(20)
        })

      {:ok, tool} =
        Tool.new(
          name: "create_account",
          description: "Create account",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["properties"]["username"]["type"] == "string"
      assert parameters["properties"]["username"]["minLength"] == 3
      assert parameters["properties"]["username"]["maxLength"] == 20
    end
  end

  describe "generates correct JSON Schema for Anthropic format" do
    test "simple Zoi schema to Anthropic format" do
      schema =
        Zoi.object(%{
          city: Zoi.string(),
          country: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "get_location_info",
          description: "Get location information",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      anthropic_schema = Schema.to_anthropic_format(tool)

      assert anthropic_schema["name"] == "get_location_info"
      assert anthropic_schema["description"] == "Get location information"

      input_schema = anthropic_schema["input_schema"]
      assert input_schema["type"] == "object"
      assert input_schema["properties"]["city"]["type"] == "string"
      assert input_schema["properties"]["country"]["type"] == "string"
    end

    test "nested Zoi schema to Anthropic format" do
      schema =
        Zoi.object(%{
          address:
            Zoi.object(%{
              street: Zoi.string(),
              city: Zoi.string()
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "save_address",
          description: "Save address",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      anthropic_schema = Schema.to_anthropic_format(tool)
      input_schema = anthropic_schema["input_schema"]

      assert input_schema["properties"]["address"]["type"] == "object"
      assert input_schema["properties"]["address"]["properties"]["street"]["type"] == "string"
      assert input_schema["properties"]["address"]["properties"]["city"]["type"] == "string"
    end
  end

  describe "generates correct JSON Schema for Google format" do
    test "simple Zoi schema to Google format" do
      schema =
        Zoi.object(%{
          query: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "search",
          description: "Search query",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      google_schema = Schema.to_google_format(tool)

      assert google_schema["name"] == "search"
      assert google_schema["description"] == "Search query"
      assert google_schema["parameters"]["type"] == "object"
      assert google_schema["parameters"]["properties"]["query"]["type"] == "string"
      refute Map.has_key?(google_schema["parameters"], "additionalProperties")
    end
  end

  describe "validates tool parameters using Zoi schema" do
    test "validates valid parameters" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "create_person",
          description: "Create person",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert validated["name"] == "Alice"
      assert validated["age"] == 30
    end

    test "validates nested object parameters" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              name: Zoi.string(),
              email: Zoi.string()
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create user",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      data = %{
        "user" => %{
          "name" => "Bob",
          "email" => "bob@example.com"
        }
      }

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert validated["user"]["name"] == "Bob"
      assert validated["user"]["email"] == "bob@example.com"
    end

    test "validates array parameters" do
      schema =
        Zoi.object(%{
          items: Zoi.array(Zoi.string())
        })

      {:ok, tool} =
        Tool.new(
          name: "process_list",
          description: "Process list",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      data = %{"items" => ["item1", "item2", "item3"]}

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert validated["items"] == ["item1", "item2", "item3"]
    end

    test "validates enum values" do
      schema =
        Zoi.object(%{
          status: Zoi.enum(["active", "inactive", "pending"])
        })

      {:ok, tool} =
        Tool.new(
          name: "set_status",
          description: "Set status",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      valid_data = %{"status" => "active"}
      assert {:ok, _} = Schema.validate(valid_data, tool.parameter_schema)

      invalid_data = %{"status" => "unknown"}
      assert {:error, _} = Schema.validate(invalid_data, tool.parameter_schema)
    end

    test "validates number constraints" do
      schema =
        Zoi.object(%{
          percentage: Zoi.number() |> Zoi.min(0) |> Zoi.max(100)
        })

      {:ok, tool} =
        Tool.new(
          name: "set_percentage",
          description: "Set percentage",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      valid_data = %{"percentage" => 50}
      assert {:ok, _} = Schema.validate(valid_data, tool.parameter_schema)

      too_low = %{"percentage" => -10}
      assert {:error, _} = Schema.validate(too_low, tool.parameter_schema)

      too_high = %{"percentage" => 150}
      assert {:error, _} = Schema.validate(too_high, tool.parameter_schema)
    end

    test "validates string constraints" do
      schema =
        Zoi.object(%{
          username: Zoi.string() |> Zoi.min(3) |> Zoi.max(20)
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create user",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      valid_data = %{"username" => "alice"}
      assert {:ok, _} = Schema.validate(valid_data, tool.parameter_schema)

      too_short = %{"username" => "ab"}
      assert {:error, _} = Schema.validate(too_short, tool.parameter_schema)

      too_long = %{"username" => String.duplicate("a", 25)}
      assert {:error, _} = Schema.validate(too_long, tool.parameter_schema)
    end

    test "validates boolean values" do
      schema =
        Zoi.object(%{
          enabled: Zoi.boolean()
        })

      {:ok, tool} =
        Tool.new(
          name: "toggle_feature",
          description: "Toggle feature",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      assert {:ok, validated} = Schema.validate(%{"enabled" => true}, tool.parameter_schema)
      assert validated["enabled"] == true

      assert {:ok, validated} = Schema.validate(%{"enabled" => false}, tool.parameter_schema)
      assert validated["enabled"] == false

      assert {:error, _} = Schema.validate(%{"enabled" => "true"}, tool.parameter_schema)
    end

    test "preserves string keys in validated data" do
      schema =
        Zoi.object(%{
          field_one: Zoi.string(),
          field_two: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      data = %{"field_one" => "value", "field_two" => 42}

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert validated["field_one"] == "value"
      assert validated["field_two"] == 42
      assert is_binary(Map.keys(validated) |> hd())
    end
  end

  describe "handles validation errors with Zoi schema" do
    test "returns error for invalid data types" do
      schema =
        Zoi.object(%{
          age: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "set_age",
          description: "Set age",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      invalid_data = %{"age" => "not_a_number"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :schema_validation_failed}} =
               Schema.validate(invalid_data, tool.parameter_schema)
    end

    test "returns error for missing required fields" do
      schema =
        Zoi.object(%{
          required_field: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "require_field",
          description: "Require field",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      incomplete_data = %{"other_field" => "value"}

      assert {:error, %ReqLLM.Error.Validation.Error{}} =
               Schema.validate(incomplete_data, tool.parameter_schema)
    end

    test "error contains helpful context" do
      schema =
        Zoi.object(%{
          email: Zoi.string(),
          age: Zoi.number()
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create user",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      invalid_data = %{"email" => 123, "age" => "invalid"}

      assert {:error, error} = Schema.validate(invalid_data, tool.parameter_schema)
      assert error.tag == :schema_validation_failed
      assert is_binary(error.reason)
      assert error.context[:data] == invalid_data
      assert error.context[:schema] == tool.parameter_schema
    end

    test "handles nested validation errors" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              age: Zoi.number()
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create user",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      invalid_data = %{
        "user" => %{
          "age" => "not_a_number"
        }
      }

      assert {:error, error} = Schema.validate(invalid_data, tool.parameter_schema)
      assert is_binary(error.reason)
    end
  end

  describe "handles nested objects in tool parameters" do
    test "creates tool with deeply nested Zoi schema" do
      schema =
        Zoi.object(%{
          company:
            Zoi.object(%{
              name: Zoi.string(),
              address:
                Zoi.object(%{
                  street: Zoi.string(),
                  city: Zoi.string(),
                  coordinates:
                    Zoi.object(%{
                      lat: Zoi.number(),
                      lng: Zoi.number()
                    })
                })
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "register_company",
          description: "Register company",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      assert tool.parameter_schema == schema
    end

    test "generates correct JSON Schema for deeply nested objects" do
      schema =
        Zoi.object(%{
          level1:
            Zoi.object(%{
              level2:
                Zoi.object(%{
                  value: Zoi.string()
                })
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "nested_tool",
          description: "Nested tool",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      openai_schema = Schema.to_openai_format(tool)
      parameters = openai_schema["function"]["parameters"]

      assert parameters["properties"]["level1"]["type"] == "object"
      assert parameters["properties"]["level1"]["properties"]["level2"]["type"] == "object"

      assert parameters["properties"]["level1"]["properties"]["level2"]["properties"]["value"][
               "type"
             ] == "string"
    end

    test "validates deeply nested object data" do
      schema =
        Zoi.object(%{
          outer:
            Zoi.object(%{
              middle:
                Zoi.object(%{
                  inner: Zoi.string()
                })
            })
        })

      {:ok, tool} =
        Tool.new(
          name: "nested_validation",
          description: "Nested validation",
          parameter_schema: schema,
          callback: &TestCallbacks.nested_callback/1
        )

      data = %{
        "outer" => %{
          "middle" => %{
            "inner" => "value"
          }
        }
      }

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert validated["outer"]["middle"]["inner"] == "value"
    end

    test "handles array of nested objects" do
      schema =
        Zoi.object(%{
          users:
            Zoi.array(
              Zoi.object(%{
                name: Zoi.string(),
                profile:
                  Zoi.object(%{
                    bio: Zoi.string(),
                    skills: Zoi.array(Zoi.string())
                  })
              })
            )
        })

      {:ok, tool} =
        Tool.new(
          name: "create_users",
          description: "Create users",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      data = %{
        "users" => [
          %{
            "name" => "Alice",
            "profile" => %{
              "bio" => "Developer",
              "skills" => ["Elixir", "Testing"]
            }
          }
        ]
      }

      assert {:ok, validated} = Schema.validate(data, tool.parameter_schema)
      assert length(validated["users"]) == 1
      assert hd(validated["users"])["name"] == "Alice"
      assert hd(validated["users"])["profile"]["skills"] == ["Elixir", "Testing"]
    end
  end

  describe "Tool execution with Zoi schemas (integration)" do
    test "executes tool with valid Zoi-validated parameters" do
      schema =
        Zoi.object(%{
          location: Zoi.string(),
          units: Zoi.optional(Zoi.string())
        })

      {:ok, tool} =
        Tool.new(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: schema,
          callback: &TestCallbacks.weather_callback/1
        )

      data = %{"location" => "San Francisco", "units" => "celsius"}

      validated_result = Schema.validate(data, tool.parameter_schema)
      assert {:ok, _validated_data} = validated_result
    end

    test "tool execution flow with schema validation delegation" do
      schema =
        Zoi.object(%{
          message: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "send_message",
          description: "Send message",
          parameter_schema: schema,
          callback: fn args ->
            msg = args["message"] || args[:message]
            {:ok, "Sent: #{msg}"}
          end
        )

      assert {:ok, result} = Tool.execute(tool, %{"message" => "hello"})
      assert result == "Sent: hello"
    end

    test "handles optional fields correctly during execution" do
      schema =
        Zoi.object(%{
          required: Zoi.string(),
          optional: Zoi.optional(Zoi.string())
        })

      {:ok, tool} =
        Tool.new(
          name: "flexible_tool",
          description: "Flexible tool",
          parameter_schema: schema,
          callback: fn args ->
            req = args["required"] || args[:required]
            opt = args["optional"] || args[:optional]
            {:ok, %{required: req, optional: opt}}
          end
        )

      with_optional = %{"required" => "value", "optional" => "present"}
      assert {:ok, result} = Tool.execute(tool, with_optional)
      assert result.required == "value"
      assert result.optional == "present"

      without_optional = %{"required" => "value"}
      assert {:ok, result} = Tool.execute(tool, without_optional)
      assert result.required == "value"
    end
  end

  describe "ReqLLM.Tool delegates to ReqLLM.Schema for Zoi operations" do
    test "to_schema delegates to Schema.to_openai_format" do
      schema =
        Zoi.object(%{
          param: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      tool_result = Tool.to_schema(tool, :openai)
      schema_result = Schema.to_openai_format(tool)

      assert tool_result == schema_result
    end

    test "to_schema delegates to Schema.to_anthropic_format" do
      schema =
        Zoi.object(%{
          param: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      tool_result = Tool.to_schema(tool, :anthropic)
      schema_result = Schema.to_anthropic_format(tool)

      assert tool_result == schema_result
    end

    test "to_schema delegates to Schema.to_google_format" do
      schema =
        Zoi.object(%{
          param: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      tool_result = Tool.to_schema(tool, :google)
      schema_result = Schema.to_google_format(tool)

      assert tool_result == schema_result
    end

    test "to_json_schema delegates properly" do
      schema =
        Zoi.object(%{
          param: Zoi.string()
        })

      {:ok, tool} =
        Tool.new(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: schema,
          callback: &TestCallbacks.simple_callback/1
        )

      compat_schema = Tool.to_json_schema(tool)
      openai_schema = Tool.to_schema(tool, :openai)

      assert compat_schema == openai_schema
    end

    test "Schema.to_json properly converts Zoi schemas" do
      zoi_schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number()
        })

      json_schema = Schema.to_json(zoi_schema)

      assert json_schema["type"] == "object"
      assert json_schema["properties"]["name"]["type"] == "string"
      assert json_schema["properties"]["age"]["type"] == "number"
      assert is_binary(Map.keys(json_schema) |> hd())
    end

    test "Schema.validate properly validates against Zoi schemas" do
      zoi_schema =
        Zoi.object(%{
          value: Zoi.string()
        })

      valid_data = %{"value" => "test"}
      assert {:ok, validated} = Schema.validate(valid_data, zoi_schema)
      assert validated["value"] == "test"

      invalid_data = %{"value" => 123}
      assert {:error, _} = Schema.validate(invalid_data, zoi_schema)
    end
  end
end
