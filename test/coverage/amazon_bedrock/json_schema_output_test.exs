defmodule ReqLLM.Coverage.AmazonBedrock.JsonSchemaOutputTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  @mantle_model %{provider: :amazon_bedrock, id: "anthropic.claude-haiku-4-5"}
  @prompt "Describe Lyon with three landmarks."
  @schema [
    name: [type: :string, required: true],
    country: [type: :string, required: true],
    landmarks: [type: {:list, :string}, required: true]
  ]

  defp opts(provider_options) do
    [
      max_tokens: 256,
      provider_options:
        [region: "eu-west-1", anthropic_structured_output_mode: :json_schema] ++ provider_options
    ]
  end

  defp assert_city(response) do
    answer = Jason.decode!(ReqLLM.Response.text(response), objects: :ordered_objects)

    assert Enum.map(answer, &elem(&1, 0)) == ["name", "country", "landmarks"]

    assert %{"name" => name, "country" => country, "landmarks" => [_ | _] = landmarks} =
             response.object

    assert is_binary(name) and is_binary(country) and Enum.all?(landmarks, &is_binary/1)
  end

  test "answers in the declared order on Converse" do
    {:ok, response} =
      ReqLLM.generate_object(
        @model,
        @prompt,
        @schema,
        fixture_opts("converse_json_schema", opts(use_converse: true))
      )

    assert_city(response)
  end

  test "answers in the declared order on InvokeModel" do
    {:ok, response} =
      ReqLLM.generate_object(
        @model,
        @prompt,
        @schema,
        fixture_opts("invoke_json_schema", opts(use_converse: false))
      )

    assert_city(response)
  end

  test "answers in the declared order on bedrock-mantle" do
    {:ok, response} =
      ReqLLM.generate_object(
        @mantle_model,
        @prompt,
        @schema,
        fixture_opts("mantle_json_schema", opts(endpoint: :mantle))
      )

    assert_city(response)
  end
end
