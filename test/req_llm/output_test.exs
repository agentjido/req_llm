defmodule ReqLLM.OutputTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Output

  @moduletag contract: :public_api

  describe "constructors" do
    test "builds text, object, array, choice, and JSON descriptors" do
      schema = [name: [type: :string, required: true]]

      assert %Output{type: :text} = Output.text()

      assert %Output{
               type: :object,
               schema: ^schema,
               name: "person",
               description: "A person"
             } = Output.object(schema, name: "person", description: "A person")

      assert %Output{type: :array, element: ^schema, name: "people"} =
               Output.array(schema, name: "people")

      assert %Output{type: :choice, choices: ["yes", "no"]} =
               Output.choice(["yes", "no"])

      assert %Output{type: :json, description: "Any JSON"} =
               Output.json(description: "Any JSON")
    end

    test "rejects invalid metadata options immediately" do
      assert_raise ArgumentError, ~r/unknown output descriptor options/, fn ->
        Output.json(mode: :strict)
      end

      assert_raise ArgumentError, ~r/:name must be a string/, fn -> Output.json(name: :value) end

      assert_raise ArgumentError, ~r/:description must be a string/, fn ->
        Output.json(description: :value)
      end
    end
  end

  describe "compile/1" do
    test "keeps text on the chat operation without a schema" do
      assert {:ok,
              %{
                operation: :chat,
                compiled_schema: nil,
                wrapped?: false,
                descriptor: %Output{type: :text}
              }} = Output.compile(Output.text())
    end

    test "normalizes NimbleOptions object schemas to JSON Schema" do
      output =
        Output.object(
          [name: [type: :string, required: true]],
          name: "person",
          description: "A generated person"
        )

      assert {:ok, contract} = Output.compile(output)
      assert contract.operation == :object
      refute contract.wrapped?
      assert contract.compiled_schema.name == "person"
      assert contract.compiled_schema.description == "A generated person"
      refute is_nil(contract.compiled_schema.compiled)

      assert contract.compiled_schema.schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string"}
               },
               "required" => ["name"],
               "propertyOrdering" => ["name"],
               "additionalProperties" => false,
               "description" => "A generated person"
             }
    end

    test "normalizes raw JSON Schema and Zoi object schemas" do
      json_schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert {:ok, json_contract} = Output.compile(Output.object(json_schema))
      assert json_contract.compiled_schema.schema == json_schema

      assert {:ok, zoi_contract} =
               Output.object(Zoi.object(%{name: Zoi.string()}))
               |> Output.compile()

      assert zoi_contract.compiled_schema.schema["type"] == "object"
      assert zoi_contract.compiled_schema.schema["properties"]["name"]["type"] == "string"
    end

    test "wraps array element schemas in a provider-compatible object" do
      output =
        Output.array(
          [name: [type: :string, required: true]],
          name: "people",
          description: "Generated people"
        )

      assert {:ok, contract} = Output.compile(output)
      assert contract.wrapped?
      assert contract.compiled_schema.name == "people"
      refute is_nil(contract.compiled_schema.compiled)

      assert get_in(contract.compiled_schema.schema, ["properties", "value", "type"]) ==
               "array"

      assert get_in(contract.compiled_schema.schema, [
               "properties",
               "value",
               "items",
               "type"
             ]) == "object"

      assert contract.compiled_schema.schema["required"] == ["value"]
      assert contract.compiled_schema.schema["additionalProperties"] == false
      assert contract.compiled_schema.schema["description"] == "Generated people"
    end

    test "supports primitive array elements through Zoi or JSON Schema" do
      assert {:ok, zoi_contract} = Output.compile(Output.array(Zoi.string()))

      assert get_in(zoi_contract.compiled_schema.schema, [
               "properties",
               "value",
               "items",
               "type"
             ]) == "string"

      assert {:ok, json_contract} =
               Output.compile(Output.array(%{"type" => "integer"}))

      assert get_in(json_contract.compiled_schema.schema, [
               "properties",
               "value",
               "items"
             ]) == %{"type" => "integer"}
    end

    test "wraps choice and arbitrary JSON values" do
      assert {:ok, choice_contract} = Output.compile(Output.choice(["sunny", "rainy"]))
      refute is_nil(choice_contract.compiled_schema.compiled)

      assert get_in(choice_contract.compiled_schema.schema, [
               "properties",
               "value"
             ]) == %{"type" => "string", "enum" => ["sunny", "rainy"]}

      assert {:ok, json_contract} = Output.compile(Output.json())
      assert get_in(json_contract.compiled_schema.schema, ["properties", "value"]) == %{}
    end

    test "rejects invalid descriptor contracts" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Output.compile(Output.object(%{"type" => "array", "items" => %{}}))

      assert message =~ "top-level object schema"

      for choices <- [[], ["yes", :no], ["yes", "yes"]] do
        assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
                 Output.compile(Output.choice(choices))
      end

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Output.normalize(%{type: :text})

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: schema_message}} =
               Output.compile(Output.object(name: [required: "yes"]))

      assert schema_message =~ "invalid output schema"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: metadata_message}} =
               Output.normalize(%Output{type: :text, name: :invalid})

      assert metadata_message =~ ":name must be a string"
    end
  end
end
