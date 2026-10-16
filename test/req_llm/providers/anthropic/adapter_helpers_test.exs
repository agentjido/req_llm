defmodule ReqLLM.Providers.Anthropic.AdapterHelpersTest do
  use ExUnit.Case, async: true

  @moduletag category: :core
  @moduletag provider: :anthropic

  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.AdapterHelpers

  @json_schema %{
    "type" => "object",
    "properties" => %{
      "question" => %{"type" => "string"},
      "options" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "minItems" => 4,
        "maxItems" => 4
      }
    },
    "required" => ["options", "question"],
    "additionalProperties" => true,
    "propertyOrdering" => ["options", "question"]
  }

  defp compiled, do: elem(ReqLLM.Schema.compile(@json_schema), 1)

  describe "prepare_structured_output_context/2" do
    test "builds a best-effort (non-strict) structured_output tool with the schema untouched" do
      opts = [compiled_schema: compiled()]
      {_context, updated_opts} = AdapterHelpers.prepare_structured_output_context(%{}, opts)
      [tool | _] = Keyword.fetch!(updated_opts, :tools)
      formatted = Anthropic.tool_to_anthropic_format(tool)

      refute Map.has_key?(formatted, :strict)
      assert formatted[:input_schema]["properties"]["options"]["minItems"] == 4

      assert Keyword.fetch!(updated_opts, :tool_choice) == %{
               type: "tool",
               name: "structured_output"
             }
    end
  end

  describe "structured_output_mode/1" do
    test "defaults to :auto and reads top-level or nested provider_options" do
      assert AdapterHelpers.structured_output_mode([]) == :auto

      assert AdapterHelpers.structured_output_mode(anthropic_structured_output_mode: :json_schema) ==
               :json_schema

      assert AdapterHelpers.structured_output_mode(
               provider_options: [anthropic_structured_output_mode: :json_schema]
             ) == :json_schema
    end
  end

  describe "strict_json_schema/1 (output_config.format reduction)" do
    test "strips unsupported keywords and forces required + additionalProperties:false" do
      reduced = AdapterHelpers.strict_json_schema(compiled())
      options = reduced["properties"]["options"]

      refute Map.has_key?(options, "minItems")
      refute Map.has_key?(options, "maxItems")
      assert options["type"] == "array"
      assert options["items"] == %{"type" => "string"}
      refute Map.has_key?(reduced, "propertyOrdering")
      assert reduced["additionalProperties"] == false
      assert Enum.sort(reduced["required"]) == ["options", "question"]
    end

    test "keeps the property order a keyword schema declares" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(
          type: [type: :string, required: true],
          text: [type: :string],
          apple: [type: :string]
        )

      reduced = AdapterHelpers.strict_json_schema(compiled)

      assert property_names(reduced) == ["type", "text", "apple"]
      assert reduced["required"] == ["type", "text", "apple"]
    end

    test "keeps the property order of an ordered JSON Schema" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(%{
          "type" => "object",
          "properties" =>
            Jason.OrderedObject.new([
              {"type", %{"type" => "string"}},
              {"text", %{"type" => "string", "maxLength" => 150}}
            ])
        })

      reduced = AdapterHelpers.strict_json_schema(compiled)

      assert property_names(reduced) == ["type", "text"]
      assert reduced["properties"]["text"] == %{"type" => "string"}
      assert reduced["required"] == ["type", "text"]
    end

    test "keeps the order a nested schema declares inside ordered properties" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(%{
          "type" => "object",
          "properties" =>
            Jason.OrderedObject.new([
              {"city",
               %{
                 "type" => "object",
                 "properties" => %{
                   "zebra" => %{"type" => "string"},
                   "apple" => %{"type" => "string"}
                 },
                 "propertyOrdering" => ["zebra", "apple"]
               }}
            ])
        })

      reduced = AdapterHelpers.strict_json_schema(compiled)

      assert property_names(reduced["properties"]["city"]) == ["zebra", "apple"]
    end

    test "reduces an atom-keyed schema in its declared order" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(%{
          type: "object",
          properties:
            Jason.OrderedObject.new(
              country: %{type: "string"},
              cities: %{type: "array", items: %{"$ref": "#/$defs/city"}}
            ),
          "$defs": %{
            city:
              Jason.OrderedObject.new(
                type: "object",
                properties:
                  Jason.OrderedObject.new(
                    name: %{type: "string", maxLength: 150},
                    area: %{type: "number"}
                  )
              )
          }
        })

      reduced = AdapterHelpers.strict_json_schema(compiled)
      city = reduced["$defs"]["city"]

      assert property_names(reduced) == ["country", "cities"]
      assert reduced["required"] == ["country", "cities"]
      assert reduced["additionalProperties"] == false
      assert property_names(city) == ["name", "area"]
      assert city["properties"]["name"] == %{"type" => "string"}
    end
  end

  defp property_names(schema), do: Enum.map(schema["properties"], &elem(&1, 0))
end
