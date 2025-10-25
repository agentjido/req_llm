defmodule ReqLLM.Schema.ZoiMetadataTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Schema
  alias ReqLLM.Tool

  @moduletag :zoi

  describe "to_json/1 preserves metadata descriptions" do
    test "for string fields" do
      schema = Zoi.string(metadata: [description: "User's full name"])
      json = Schema.to_json(schema)

      assert json["description"] == "User's full name"
      assert json["type"] == "string"
    end

    test "for number fields" do
      schema = Zoi.number(metadata: [description: "Age in years"])
      json = Schema.to_json(schema)

      assert json["description"] == "Age in years"
      assert json["type"] == "number"
    end

    test "for boolean fields" do
      schema = Zoi.boolean(metadata: [description: "Whether user is active"])
      json = Schema.to_json(schema)

      assert json["description"] == "Whether user is active"
      assert json["type"] == "boolean"
    end

    test "for enum fields" do
      schema =
        Zoi.enum(["active", "inactive", "pending"],
          metadata: [description: "User account status"]
        )

      json = Schema.to_json(schema)

      assert json["description"] == "User account status"
      assert json["enum"] == ["active", "inactive", "pending"]
    end

    test "for array fields" do
      schema = Zoi.array(Zoi.string(), metadata: [description: "List of user tags"])
      json = Schema.to_json(schema)

      assert json["description"] == "List of user tags"
      assert json["type"] == "array"
      assert json["items"]["type"] == "string"
    end

    test "in object field properties" do
      schema =
        Zoi.object(%{
          name: Zoi.string(metadata: [description: "User's full name"]),
          age: Zoi.number(metadata: [description: "Age in years"]),
          email: Zoi.string(metadata: [description: "Email address"])
        })

      json = Schema.to_json(schema)

      assert json["type"] == "object"
      assert json["properties"]["name"]["description"] == "User's full name"
      assert json["properties"]["age"]["description"] == "Age in years"
      assert json["properties"]["email"]["description"] == "Email address"
    end

    test "in nested object hierarchies" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(
              %{
                name: Zoi.string(metadata: [description: "User's name"]),
                profile:
                  Zoi.object(
                    %{
                      bio: Zoi.string(metadata: [description: "User biography"])
                    },
                    metadata: [description: "User profile information"]
                  )
              },
              metadata: [description: "User details"]
            )
        })

      json = Schema.to_json(schema)

      assert json["properties"]["user"]["description"] == "User details"
      assert json["properties"]["user"]["properties"]["name"]["description"] == "User's name"

      assert json["properties"]["user"]["properties"]["profile"]["description"] ==
               "User profile information"

      assert json["properties"]["user"]["properties"]["profile"]["properties"]["bio"][
               "description"
             ] == "User biography"
    end

    test "alongside field constraints" do
      schema =
        Zoi.object(%{
          username:
            Zoi.string(metadata: [description: "Username (3-20 characters)"])
            |> Zoi.min(3)
            |> Zoi.max(20),
          age:
            Zoi.number(metadata: [description: "Age (must be 0-120)"])
            |> Zoi.min(0)
            |> Zoi.max(120)
        })

      json = Schema.to_json(schema)

      assert json["properties"]["username"]["description"] == "Username (3-20 characters)"
      assert json["properties"]["username"]["minLength"] == 3
      assert json["properties"]["username"]["maxLength"] == 20

      assert json["properties"]["age"]["description"] == "Age (must be 0-120)"
      assert json["properties"]["age"]["minimum"] == 0
      assert json["properties"]["age"]["maximum"] == 120
    end

    test "for optional fields" do
      schema =
        Zoi.object(%{
          required: Zoi.string(metadata: [description: "Required field"]),
          optional: Zoi.optional(Zoi.string(metadata: [description: "Optional field"]))
        })

      json = Schema.to_json(schema)

      assert json["properties"]["required"]["description"] == "Required field"
      assert json["properties"]["optional"]["description"] == "Optional field"
    end

    test "in array of objects" do
      schema =
        Zoi.array(
          Zoi.object(%{
            id: Zoi.number(metadata: [description: "Item ID"]),
            name: Zoi.string(metadata: [description: "Item name"])
          }),
          metadata: [description: "List of items"]
        )

      json = Schema.to_json(schema)

      assert json["description"] == "List of items"
      assert json["items"]["properties"]["id"]["description"] == "Item ID"
      assert json["items"]["properties"]["name"]["description"] == "Item name"
    end
  end

  describe "Tool integration preserves metadata descriptions" do
    test "in OpenAI format" do
      schema =
        Zoi.object(%{
          location: Zoi.string(metadata: [description: "City name or ZIP code"]),
          units: Zoi.enum(["celsius", "fahrenheit"], metadata: [description: "Temperature units"])
        })

      {:ok, tool} =
        Tool.new(
          name: "get_weather",
          description: "Get weather for a location",
          parameter_schema: schema,
          callback: fn _args -> {:ok, %{}} end
        )

      openai_format = Schema.to_openai_format(tool)
      params = openai_format["function"]["parameters"]

      assert params["properties"]["location"]["description"] == "City name or ZIP code"
      assert params["properties"]["units"]["description"] == "Temperature units"
    end

    test "in Anthropic format" do
      schema =
        Zoi.object(%{
          query: Zoi.string(metadata: [description: "Search query string"]),
          max_results:
            Zoi.number(metadata: [description: "Maximum number of results"])
            |> Zoi.min(1)
            |> Zoi.max(100)
        })

      {:ok, tool} =
        Tool.new(
          name: "search",
          description: "Search for information",
          parameter_schema: schema,
          callback: fn _args -> {:ok, []} end
        )

      anthropic_format = Schema.to_anthropic_format(tool)
      input_schema = anthropic_format["input_schema"]

      assert input_schema["properties"]["query"]["description"] == "Search query string"

      assert input_schema["properties"]["max_results"]["description"] ==
               "Maximum number of results"
    end

    test "in Google format" do
      schema =
        Zoi.object(%{
          path: Zoi.string(metadata: [description: "File path"]),
          operation:
            Zoi.enum(["read", "write", "delete"],
              metadata: [description: "File operation to perform"]
            )
        })

      {:ok, tool} =
        Tool.new(
          name: "file_operation",
          description: "Perform file operations",
          parameter_schema: schema,
          callback: fn _args -> {:ok, "success"} end
        )

      google_format = Schema.to_google_format(tool)
      params = google_format["parameters"]

      assert params["properties"]["path"]["description"] == "File path"
      assert params["properties"]["operation"]["description"] == "File operation to perform"
    end

    test "for complex nested schemas" do
      schema =
        Zoi.object(%{
          user:
            Zoi.object(
              %{
                name: Zoi.string(metadata: [description: "Full name"]),
                contact:
                  Zoi.object(
                    %{
                      email: Zoi.string(metadata: [description: "Email address"]),
                      phone: Zoi.string(metadata: [description: "Phone number"])
                    },
                    metadata: [description: "Contact information"]
                  )
              },
              metadata: [description: "User information"]
            ),
          metadata:
            Zoi.object(
              %{
                created_at: Zoi.string(metadata: [description: "Creation timestamp"]),
                tags: Zoi.array(Zoi.string(), metadata: [description: "Associated tags"])
              },
              metadata: [description: "Metadata fields"]
            )
        })

      {:ok, tool} =
        Tool.new(
          name: "create_user",
          description: "Create a new user",
          parameter_schema: schema,
          callback: fn _args -> {:ok, %{}} end
        )

      openai_format = Schema.to_openai_format(tool)
      props = openai_format["function"]["parameters"]["properties"]

      assert props["user"]["description"] == "User information"
      assert props["user"]["properties"]["name"]["description"] == "Full name"
      assert props["user"]["properties"]["contact"]["description"] == "Contact information"

      assert props["user"]["properties"]["contact"]["properties"]["email"]["description"] ==
               "Email address"

      assert props["user"]["properties"]["contact"]["properties"]["phone"]["description"] ==
               "Phone number"

      assert props["metadata"]["description"] == "Metadata fields"

      assert props["metadata"]["properties"]["created_at"]["description"] ==
               "Creation timestamp"

      assert props["metadata"]["properties"]["tags"]["description"] == "Associated tags"
    end
  end

  describe "multiple metadata fields" do
    test "preserves description alongside other metadata" do
      schema =
        Zoi.string(
          metadata: [
            description: "User's email",
            example: "user@example.com",
            format: "email"
          ]
        )

      json = Schema.to_json(schema)

      assert json["description"] == "User's email"
      assert json["type"] == "string"
    end

    test "object-level metadata coexists with field descriptions" do
      schema =
        Zoi.object(
          %{
            name: Zoi.string(metadata: [description: "Name field"]),
            age: Zoi.number(metadata: [description: "Age field"])
          },
          metadata: [
            description: "User schema",
            example: %{name: "Alice", age: 30}
          ]
        )

      json = Schema.to_json(schema)

      assert json["description"] == "User schema"
      assert json["properties"]["name"]["description"] == "Name field"
      assert json["properties"]["age"]["description"] == "Age field"
    end
  end

  describe "edge cases" do
    test "schemas without description metadata" do
      schema = Zoi.string()
      json = Schema.to_json(schema)

      refute Map.has_key?(json, "description")
      assert json["type"] == "string"
    end

    test "empty description strings" do
      schema = Zoi.string(metadata: [description: ""])
      json = Schema.to_json(schema)

      assert json["description"] == ""
    end

    test "mixed described and undescribed fields" do
      schema =
        Zoi.object(%{
          with_desc: Zoi.string(metadata: [description: "Has description"]),
          without_desc: Zoi.string()
        })

      json = Schema.to_json(schema)

      assert json["properties"]["with_desc"]["description"] == "Has description"
      refute Map.has_key?(json["properties"]["without_desc"], "description")
    end
  end
end
