defmodule ReqLLM.ProviderTest.ObjectGeneration do
  @moduledoc """
  Object generation tests.

  Tests structured object generation capabilities:
  - Basic object generation with schemas
  - Streaming object generation
  - JSON delta accumulation for streaming
  - Schema validation and adherence

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.ObjectGenerationTest do
        use ReqLLM.ProviderTest.ObjectGeneration, provider: :anthropic
      end

  This will generate tests for all models selected by ModelMatrix for the provider.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ReqLLM.Context
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :object_generation
      @moduletag provider: provider

      @provider provider
      @models ModelMatrix.models_for_provider(provider)

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          test "basic non-streaming object generation" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_basic_object"

            schema = [
              name: [type: :string, required: true, doc: "Person's full name"],
              age: [type: :pos_integer, required: true, doc: "Person's age in years"],
              occupation: [type: :string, doc: "Person's job or profession"]
            ]

            {:ok, response} =
              ReqLLM.generate_object(
                @model_spec,
                "Generate a fictional character profile",
                schema,
                fixture_opts(
                  @provider,
                  fixture_name,
                  param_bundles(@provider).deterministic
                )
              )

            object = ReqLLM.Response.object(response)

            assert is_map(object)
            assert map_size(object) > 0
            assert Map.has_key?(object, "name")
            assert Map.has_key?(object, "age")
            assert is_binary(object["name"])
            assert is_integer(object["age"])
            assert object["name"] != ""
            assert object["age"] > 0
          end

          test "streaming object generation" do
            model_name =
              @model_spec |> String.split(":") |> List.last() |> String.replace("-", "_")

            fixture_name = "#{model_name}_streaming_object"

            schema = [
              name: [type: :string, required: true, doc: "Person's full name"],
              age: [type: :pos_integer, required: true, doc: "Person's age in years"],
              occupation: [type: :string, doc: "Person's job or profession"]
            ]

            {:ok, response} =
              ReqLLM.stream_object(
                @model_spec,
                "Generate a software engineer profile",
                schema,
                fixture_opts(
                  @provider,
                  fixture_name,
                  Keyword.put(param_bundles(@provider).deterministic, :max_tokens, 200)
                )
              )

            response =
              if match?(%ReqLLM.StreamResponse{}, response) do
                {:ok, resp} = ReqLLM.StreamResponse.to_response(response)
                resp
              else
                response
              end

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
      end
    end
  end
end
