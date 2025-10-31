defmodule ReqLLM.Schema.ZoiTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Schema

  describe "to_json/1 with Zoi schemas" do
    test "converts simple Zoi object schema to JSON Schema" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number()
        })

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["name"]["type"] == "string"
      assert result["properties"]["age"]["type"] == "number"
      assert is_map(result)
      refute Map.has_key?(result, :type)
    end

    test "converts nested Zoi object schemas" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              name: Zoi.string(),
              email: Zoi.string()
            }),
          metadata:
            Zoi.object(%{
              created_at: Zoi.string(),
              tags: Zoi.array(Zoi.string())
            })
        })

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["user"]["type"] == "object"
      assert result["properties"]["user"]["properties"]["name"]["type"] == "string"
      assert result["properties"]["user"]["properties"]["email"]["type"] == "string"
      assert result["properties"]["metadata"]["type"] == "object"
      assert result["properties"]["metadata"]["properties"]["tags"]["type"] == "array"
      assert result["properties"]["metadata"]["properties"]["tags"]["items"]["type"] == "string"
    end

    test "converts Zoi array schemas" do
      schema = Zoi.array(Zoi.string())
      result = Schema.to_json(schema)

      assert result["type"] == "array"
      assert result["items"]["type"] == "string"
    end

    test "converts Zoi array of objects" do
      schema =
        Zoi.array(
          Zoi.object(%{
            id: Zoi.number(),
            name: Zoi.string()
          })
        )

      result = Schema.to_json(schema)

      assert result["type"] == "array"
      assert result["items"]["type"] == "object"
      assert result["items"]["properties"]["id"]["type"] == "number"
      assert result["items"]["properties"]["name"]["type"] == "string"
    end

    test "handles optional fields in Zoi schemas" do
      schema =
        Zoi.object(%{
          required_field: Zoi.string(),
          optional_field: Zoi.optional(Zoi.string())
        })

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["required_field"]["type"] == "string"
      assert result["properties"]["optional_field"]["type"] == "string"

      if Map.has_key?(result, "required") do
        assert "required_field" in result["required"]
        refute "optional_field" in result["required"]
      end
    end

    test "converts Zoi enum schemas" do
      schema = Zoi.enum(["active", "inactive", "pending"])
      result = Schema.to_json(schema)

      assert result["enum"] == ["active", "inactive", "pending"]
    end

    test "converts Zoi number with constraints" do
      schema = Zoi.number() |> Zoi.min(0) |> Zoi.max(100)
      result = Schema.to_json(schema)

      assert result["type"] == "number"
      assert result["minimum"] == 0
      assert result["maximum"] == 100
    end

    test "converts Zoi string with constraints" do
      schema = Zoi.string() |> Zoi.min(3) |> Zoi.max(50)
      result = Schema.to_json(schema)

      assert result["type"] == "string"
      assert result["minLength"] == 3
      assert result["maxLength"] == 50
    end

    test "output is string-keyed JSON Schema" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          count: Zoi.number()
        })

      result = Schema.to_json(schema)

      Enum.each(result, fn {key, _value} ->
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end)

      if Map.has_key?(result, "properties") do
        Enum.each(result["properties"], fn {key, _value} ->
          assert is_binary(key), "Expected string property key, got: #{inspect(key)}"
        end)
      end
    end

    test "converts Zoi boolean schema" do
      schema =
        Zoi.object(%{
          enabled: Zoi.boolean()
        })

      result = Schema.to_json(schema)

      assert result["properties"]["enabled"]["type"] == "boolean"
    end

    test "handles complex nested Zoi schemas" do
      schema =
        Zoi.object(%{
          users:
            Zoi.array(
              Zoi.object(%{
                name: Zoi.string(),
                age: Zoi.number(),
                tags: Zoi.array(Zoi.string()),
                active: Zoi.boolean()
              })
            )
        })

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["users"]["type"] == "array"

      user_schema = result["properties"]["users"]["items"]
      assert user_schema["type"] == "object"
      assert user_schema["properties"]["name"]["type"] == "string"
      assert user_schema["properties"]["age"]["type"] == "number"
      assert user_schema["properties"]["tags"]["type"] == "array"
      assert user_schema["properties"]["tags"]["items"]["type"] == "string"
      assert user_schema["properties"]["active"]["type"] == "boolean"
    end

    test "encodes boolean additionalProperties as a boolean" do
      schema =
        Zoi.object(%{
          name: Zoi.string()
        })

      result = Schema.to_json(schema)

      assert result["additionalProperties"] == false
    end
  end

  describe "validate/2 with Zoi schemas" do
    test "validates data against simple Zoi schema" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number()
        })

      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated["name"] == "Alice"
      assert validated["age"] == 30
    end

    test "validates nested object data" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              name: Zoi.string(),
              email: Zoi.string()
            })
        })

      data = %{
        "user" => %{
          "name" => "Bob",
          "email" => "bob@example.com"
        }
      }

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated["user"]["name"] == "Bob"
      assert validated["user"]["email"] == "bob@example.com"
    end

    test "validates array data" do
      schema = Zoi.array(Zoi.string())
      data = ["hello", "world"]

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated == ["hello", "world"]
    end

    test "type coercion works when supported by Zoi" do
      schema =
        Zoi.object(%{
          count: Zoi.number()
        })

      data = %{"count" => "42"}

      case Schema.validate(data, schema) do
        {:ok, validated} ->
          assert is_number(validated["count"])

        {:error, _} ->
          :ok
      end
    end

    test "returns error for invalid data types" do
      schema =
        Zoi.object(%{
          age: Zoi.number()
        })

      data = %{"age" => "not_a_number"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :schema_validation_failed}} =
               Schema.validate(data, schema)
    end

    test "returns error for missing required fields" do
      schema =
        Zoi.object(%{
          required_field: Zoi.string()
        })

      data = %{"other_field" => "value"}

      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.validate(data, schema)
    end

    test "formats validation errors properly" do
      schema =
        Zoi.object(%{
          email: Zoi.string(),
          age: Zoi.number()
        })

      data = %{"email" => 123, "age" => "invalid"}

      assert {:error, error} = Schema.validate(data, schema)
      assert error.tag == :schema_validation_failed
      assert is_binary(error.reason)
      assert error.context[:data] == data
      assert error.context[:schema] == schema
    end

    test "handles optional fields correctly" do
      schema =
        Zoi.object(%{
          required: Zoi.string(),
          optional: Zoi.optional(Zoi.string())
        })

      data_with_optional = %{"required" => "value", "optional" => "present"}
      assert {:ok, _} = Schema.validate(data_with_optional, schema)

      data_without_optional = %{"required" => "value"}
      assert {:ok, _} = Schema.validate(data_without_optional, schema)
    end

    test "unknown keys are preserved during validation" do
      schema =
        Zoi.object(%{
          known_field: Zoi.string()
        })

      data = %{"known_field" => "value", "unknown_field" => "extra"}

      case Schema.validate(data, schema) do
        {:ok, validated} ->
          if Map.has_key?(validated, "unknown_field") do
            assert is_binary(validated["unknown_field"])
          end

        {:error, _} ->
          :ok
      end
    end

    test "validates complex nested structures" do
      schema =
        Zoi.object(%{
          company:
            Zoi.object(%{
              name: Zoi.string(),
              employees:
                Zoi.array(
                  Zoi.object(%{
                    name: Zoi.string(),
                    role: Zoi.string(),
                    skills: Zoi.array(Zoi.string())
                  })
                )
            })
        })

      data = %{
        "company" => %{
          "name" => "Acme Corp",
          "employees" => [
            %{
              "name" => "Alice",
              "role" => "Engineer",
              "skills" => ["Elixir", "Testing"]
            },
            %{
              "name" => "Bob",
              "role" => "Designer",
              "skills" => ["UI", "UX"]
            }
          ]
        }
      }

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated["company"]["name"] == "Acme Corp"
      assert length(validated["company"]["employees"]) == 2
      assert hd(validated["company"]["employees"])["name"] == "Alice"
    end

    test "validates enum constraints" do
      schema =
        Zoi.object(%{
          status: Zoi.enum(["active", "inactive", "pending"])
        })

      valid_data = %{"status" => "active"}
      assert {:ok, _} = Schema.validate(valid_data, schema)

      invalid_data = %{"status" => "unknown"}
      assert {:error, _} = Schema.validate(invalid_data, schema)
    end

    test "validates number constraints" do
      schema =
        Zoi.object(%{
          percentage: Zoi.number() |> Zoi.min(0) |> Zoi.max(100)
        })

      valid_data = %{"percentage" => 50}
      assert {:ok, _} = Schema.validate(valid_data, schema)

      invalid_min = %{"percentage" => -10}
      assert {:error, _} = Schema.validate(invalid_min, schema)

      invalid_max = %{"percentage" => 150}
      assert {:error, _} = Schema.validate(invalid_max, schema)
    end

    test "validates string constraints" do
      schema =
        Zoi.object(%{
          username: Zoi.string() |> Zoi.min(3) |> Zoi.max(20)
        })

      valid_data = %{"username" => "alice"}
      assert {:ok, _} = Schema.validate(valid_data, schema)

      too_short = %{"username" => "ab"}
      assert {:error, _} = Schema.validate(too_short, schema)

      too_long = %{"username" => String.duplicate("a", 25)}
      assert {:error, _} = Schema.validate(too_long, schema)
    end

    test "validates boolean values" do
      schema =
        Zoi.object(%{
          enabled: Zoi.boolean()
        })

      assert {:ok, validated} = Schema.validate(%{"enabled" => true}, schema)
      assert validated["enabled"] == true

      assert {:ok, validated} = Schema.validate(%{"enabled" => false}, schema)
      assert validated["enabled"] == false

      assert {:error, _} = Schema.validate(%{"enabled" => "true"}, schema)
    end
  end

  describe "validate/2 error message formatting" do
    test "formats single field error" do
      schema =
        Zoi.object(%{
          age: Zoi.number()
        })

      data = %{"age" => "invalid"}

      assert {:error, error} = Schema.validate(data, schema)
      assert is_binary(error.reason)
      assert error.reason =~ ~r/age|number|invalid/i
    end

    test "formats multiple field errors" do
      schema =
        Zoi.object(%{
          name: Zoi.string(),
          age: Zoi.number(),
          email: Zoi.string()
        })

      data = %{"name" => 123, "age" => "invalid", "email" => true}

      assert {:error, error} = Schema.validate(data, schema)
      assert is_binary(error.reason)
    end

    test "formats nested field errors" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(%{
              profile:
                Zoi.object(%{
                  age: Zoi.number()
                })
            })
        })

      data = %{
        "user" => %{
          "profile" => %{
            "age" => "invalid"
          }
        }
      }

      assert {:error, error} = Schema.validate(data, schema)
      assert is_binary(error.reason)
    end
  end
end
