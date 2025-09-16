defmodule ReqLLM.Coverage.Anthropic.ObjectGenerationTest do
  @moduledoc """
  Anthropic object generation API feature coverage tests.

  Tests the streaming object generation fix that properly accumulates
  JSON deltas from input_json_delta events, ensuring complete objects
  are returned instead of empty maps.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.ObjectGeneration,
    provider: :anthropic,
    model: "anthropic:claude-3-5-sonnet-20241022"

  # Additional Anthropic-specific object generation tests
  describe "anthropic specific object generation" do
    test "streaming object with anthropic-specific features" do
      # Test the specific fix for Anthropic's input_json_delta accumulation
      schema = [
        character_name: [type: :string, required: true, doc: "Fantasy character name"],
        character_class: [type: :string, required: true, doc: "Character class or profession"],
        level: [type: :pos_integer, required: true, doc: "Character level (1-20)"],
        abilities: [type: {:list, :string}, doc: "List of special abilities"],
        backstory: [type: :string, doc: "Brief character backstory"]
      ]

      {:ok, response} =
        ReqLLM.stream_object(
          "anthropic:claude-3-5-sonnet-20241022",
          "Create a detailed fantasy RPG character with abilities and backstory",
          schema,
          fixture_opts(
            :anthropic,
            "anthropic_streaming_object_fix",
            param_bundles().deterministic
          )
        )

      if response.stream? do
        # This is the key test for the streaming object fix
        # Before the fix: would return [%{}] (empty objects)
        # After the fix: should return complete objects with all fields

        assert response.stream?

        # Collect streaming objects
        objects =
          response
          |> ReqLLM.Response.object_stream()
          |> Enum.to_list()

        # Should have at least one object
        assert length(objects) >= 1

        [first_object | _] = objects

        # The critical assertion: object should NOT be empty
        # This validates that JSON delta accumulation is working
        assert is_map(first_object)
        assert map_size(first_object) > 0
        refute first_object == %{}

        # Verify required fields are present with valid data
        assert Map.has_key?(first_object, "character_name")
        assert Map.has_key?(first_object, "character_class")
        assert Map.has_key?(first_object, "level")

        assert is_binary(first_object["character_name"])
        assert first_object["character_name"] != ""
        assert is_binary(first_object["character_class"])
        assert first_object["character_class"] != ""
        assert is_integer(first_object["level"])
        assert first_object["level"] > 0 and first_object["level"] <= 20

        # Optional fields should be valid if present
        if Map.has_key?(first_object, "abilities") do
          assert is_list(first_object["abilities"])
          assert Enum.all?(first_object["abilities"], &is_binary/1)
        end

        if Map.has_key?(first_object, "backstory") do
          assert is_binary(first_object["backstory"])
          assert first_object["backstory"] != ""
        end
      else
        # Fixture mode: verify the materialized object is complete
        object = ReqLLM.Response.object(response)

        assert is_map(object)
        assert map_size(object) > 0
        refute object == %{}

        # Basic field validation
        assert Map.has_key?(object, "character_name")
        assert is_binary(object["character_name"])
        assert object["character_name"] != ""
      end
    end

    test "streaming tool call argument accumulation validation" do
      # This test specifically validates that the StreamDecoder properly
      # accumulates input_json_delta events for tool calls

      schema = [
        product_name: [type: :string, required: true, doc: "Product name"],
        price: [type: :float, required: true, doc: "Product price in USD"],
        category: [type: :string, required: true, doc: "Product category"],
        features: [type: {:list, :string}, doc: "Key product features"],
        in_stock: [type: :boolean, doc: "Whether product is in stock"]
      ]

      {:ok, response} =
        ReqLLM.stream_object(
          "anthropic:claude-3-5-sonnet-20241022",
          "Generate a product listing for an electronic device with multiple features",
          schema,
          fixture_opts(
            :anthropic,
            "streaming_tool_call_accumulation",
            param_bundles().deterministic
          )
        )

      if response.stream? do
        # Verify streaming response structure
        assert response.stream?
        assert response.stream

        # Test that we can collect the stream without errors
        chunks = Enum.to_list(response.stream)
        assert is_list(chunks)
        refute Enum.empty?(chunks)

        # Find tool call chunks
        tool_call_chunks =
          chunks
          |> Enum.filter(fn chunk ->
            match?(%ReqLLM.StreamChunk{type: :tool_call}, chunk)
          end)

        assert length(tool_call_chunks) >= 1

        # Verify the tool call has proper arguments (not empty)
        [first_tool_call | _] = tool_call_chunks

        assert first_tool_call.name == "structured_output"
        assert is_map(first_tool_call.arguments)
        assert map_size(first_tool_call.arguments) > 0

        # This is the key validation: arguments should not be empty
        # This proves the JSON delta accumulation is working correctly
        refute first_tool_call.arguments == %{}

        # Get objects via object_stream to test the full pipeline
        objects =
          response
          |> ReqLLM.Response.object_stream()
          |> Enum.to_list()

        assert length(objects) >= 1
        [object | _] = objects

        # Final validation: complete object with all required fields
        assert is_map(object)
        # At least required fields
        assert map_size(object) >= 3

        for field <- ["product_name", "price", "category"] do
          assert Map.has_key?(object, field), "Missing required field: #{field}"
          assert object[field] != nil, "Required field #{field} is nil"
        end

        assert is_binary(object["product_name"])
        assert is_float(object["price"]) or is_integer(object["price"])
        assert is_binary(object["category"])
      end
    end
  end
end
