defmodule ReqLLM.ProviderTest.ObjectGeneration do
  @moduledoc """
  Object generation tests.

  Tests structured object generation capabilities:
  - Basic object generation with schemas
  - Streaming object generation
  - JSON delta accumulation for streaming
  - Schema validation and adherence
  - Complex nested object handling
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    quote bind_quoted: [provider: provider, model: model] do
      use ExUnit.Case, async: false

      import ReqLLM.Context
      import ReqLLM.ProviderTestHelpers

      @moduletag :capture_log
      @moduletag :coverage
      @moduletag category: :object_generation
      @moduletag provider: provider

      describe "object generation" do
        test "basic non-streaming object generation" do
          schema = [
            name: [type: :string, required: true, doc: "Person's full name"],
            age: [type: :pos_integer, required: true, doc: "Person's age in years"],
            occupation: [type: :string, doc: "Person's job or profession"],
            hobbies: [type: {:list, :string}, doc: "List of hobbies and interests"]
          ]

          {:ok, response} =
            ReqLLM.generate_object(
              unquote(model),
              "Generate a fictional character profile with name, age, occupation, and hobbies",
              schema,
              fixture_opts(
                unquote(provider),
                "basic_object_generation",
                param_bundles().deterministic
              )
            )

          # Verify we got a successful response
          assert response.message
          assert response.message.content

          # Extract the object from the response
          object = ReqLLM.Response.object(response)

          # Verify it's a valid map with expected structure
          assert is_map(object)
          assert map_size(object) > 0

          # Verify required fields are present
          assert Map.has_key?(object, "name")
          assert Map.has_key?(object, "age")
          assert is_binary(object["name"])
          assert is_integer(object["age"])
          assert object["name"] != ""
          assert object["age"] > 0

          # Verify optional fields if present
          if Map.has_key?(object, "occupation") do
            assert is_binary(object["occupation"])
          end

          if Map.has_key?(object, "hobbies") do
            assert is_list(object["hobbies"])
            assert Enum.all?(object["hobbies"], &is_binary/1)
          end
        end

        test "streaming object generation with JSON delta accumulation" do
          schema = [
            name: [type: :string, required: true, doc: "Person's full name"],
            age: [type: :pos_integer, required: true, doc: "Person's age in years"],
            occupation: [type: :string, doc: "Person's job or profession"],
            skills: [type: {:list, :string}, doc: "List of professional skills"]
          ]

          {:ok, response} =
            ReqLLM.stream_object(
              unquote(model),
              "Generate a detailed profile for a software engineer with name, age, occupation, and skills",
              schema,
              fixture_opts(
                unquote(provider),
                "streaming_object_generation",
                param_bundles().deterministic
              )
            )

          # For streaming responses in the new system, check if it's truly streaming
          if response.stream? do
            # Live streaming mode: test actual streaming behavior
            # Get the object stream and collect objects
            objects =
              response
              |> ReqLLM.Response.object_stream()
              |> Enum.to_list()

            # Should have at least one object
            assert length(objects) >= 1

            # Verify the first object has complete data (not empty)
            [first_object | _] = objects
            assert is_map(first_object)
            assert map_size(first_object) > 0

            # Verify required fields are present and not empty
            assert Map.has_key?(first_object, "name")
            assert Map.has_key?(first_object, "age")
            assert is_binary(first_object["name"])
            assert first_object["name"] != ""
            assert is_integer(first_object["age"])
            assert first_object["age"] > 0

            # This is the key test: streaming should NOT return empty objects
            # The JSON delta accumulation fix should ensure complete objects
            refute first_object == %{}
          else
            # Fixture mode: response was materialized from stream
            # Extract object from the materialized response  
            object = ReqLLM.Response.object(response)

            assert is_map(object)
            assert map_size(object) > 0
            assert Map.has_key?(object, "name")
            assert Map.has_key?(object, "age")
            assert is_binary(object["name"])
            assert object["name"] != ""
            assert is_integer(object["age"])
            assert object["age"] > 0
          end
        end

        test "complex object schema generation" do
          schema = [
            company_name: [type: :string, required: true, doc: "Name of the company"],
            founded_year: [type: :pos_integer, required: true, doc: "Year company was founded"],
            headquarters_city: [type: :string, required: true, doc: "City where HQ is located"],
            headquarters_country: [
              type: :string,
              required: true,
              doc: "Country where HQ is located"
            ],
            employee_count: [type: :pos_integer, doc: "Approximate number of employees"],
            industry: [type: :string, doc: "Primary industry or sector"],
            key_products: [type: {:list, :string}, doc: "Main products or services"]
          ]

          {:ok, response} =
            ReqLLM.generate_object(
              unquote(model),
              "Generate a complete profile for a tech startup company including name, founding year, location, and other details",
              schema,
              fixture_opts(
                unquote(provider),
                "complex_object_generation",
                param_bundles().deterministic
              )
            )

          # Extract the object
          object = ReqLLM.Response.object(response)

          # Verify complex object structure
          assert is_map(object)
          # At least the required fields
          assert map_size(object) >= 4

          # Verify all required fields
          required_fields = [
            "company_name",
            "founded_year",
            "headquarters_city",
            "headquarters_country"
          ]

          for field <- required_fields do
            assert Map.has_key?(object, field), "Missing required field: #{field}"
            assert object[field] != nil, "Required field #{field} is nil"
            assert object[field] != "", "Required field #{field} is empty"
          end

          # Verify data types
          assert is_binary(object["company_name"])
          assert is_integer(object["founded_year"])
          assert is_binary(object["headquarters_city"])
          assert is_binary(object["headquarters_country"])

          # Verify optional fields if present
          if Map.has_key?(object, "employee_count") do
            assert is_integer(object["employee_count"])
            assert object["employee_count"] > 0
          end

          if Map.has_key?(object, "key_products") do
            assert is_list(object["key_products"])
            assert Enum.all?(object["key_products"], &is_binary/1)
            assert Enum.all?(object["key_products"], &(&1 != ""))
          end
        end

        test "streaming vs non-streaming object consistency" do
          schema = [
            title: [type: :string, required: true, doc: "Article title"],
            author: [type: :string, required: true, doc: "Article author"],
            word_count: [type: :pos_integer, required: true, doc: "Approximate word count"],
            tags: [type: {:list, :string}, doc: "Article tags or categories"]
          ]

          prompt = "Generate a blog article metadata"

          opts =
            fixture_opts(unquote(provider), "object_consistency", param_bundles().deterministic)

          # Non-streaming version
          {:ok, non_stream_response} =
            ReqLLM.generate_object(
              unquote(model),
              prompt,
              schema,
              fixture_opts(
                unquote(provider),
                "object_consistency_non_stream",
                param_bundles().deterministic
              )
            )

          # Streaming version  
          {:ok, stream_response} =
            ReqLLM.stream_object(
              unquote(model),
              prompt,
              schema,
              fixture_opts(
                unquote(provider),
                "object_consistency_stream",
                param_bundles().deterministic
              )
            )

          # Extract objects
          non_stream_object = ReqLLM.Response.object(non_stream_response)

          if stream_response.stream? do
            # Live streaming mode
            [stream_object | _] =
              stream_response
              |> ReqLLM.Response.object_stream()
              |> Enum.to_list()

            # Both should be valid objects with same structure
            assert is_map(non_stream_object) and map_size(non_stream_object) > 0
            assert is_map(stream_object) and map_size(stream_object) > 0

            # Both should have required fields
            for field <- ["title", "author", "word_count"] do
              assert Map.has_key?(non_stream_object, field)
              assert Map.has_key?(stream_object, field)
            end

            # Field types should be consistent
            assert is_binary(non_stream_object["title"])
            assert is_binary(stream_object["title"])
            assert is_integer(non_stream_object["word_count"])
            assert is_integer(stream_object["word_count"])
          else
            # Fixture mode - both should be materialized objects
            stream_object = ReqLLM.Response.object(stream_response)

            assert is_map(non_stream_object) and map_size(non_stream_object) > 0
            assert is_map(stream_object) and map_size(stream_object) > 0
          end
        end
      end
    end
  end
end
