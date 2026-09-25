defmodule ReqLLM.Coverage.NonStrictResponsesToolsTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag timeout: 180_000

  for model <- ["openai:gpt-5", "meta:muse-spark-1.1"] do
    @model model

    test "#{model} accepts a non-strict schema with definitions and optional fields" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather for a location",
          parameter_schema: %{
            "$schema" => "https://json-schema.org/draft/2020-12/schema",
            "$defs" => %{"location" => %{"type" => "string"}},
            "type" => "object",
            "properties" => %{
              "location" => %{"$ref" => "#/$defs/location"},
              "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
            },
            "required" => ["location"],
            "additionalProperties" => true
          },
          strict: false,
          callback: fn args -> {:ok, args} end
        )

      opts =
        fixture_opts("non_strict_tool_schema",
          tools: [tool],
          tool_choice: :auto,
          reasoning_effort: :low,
          max_tokens: 2048
        )

      assert {:ok, response} =
               ReqLLM.generate_text(@model, "Call get_weather with location London.", opts)

      assert [tool_call | _] = ReqLLM.Response.tool_calls(response)
      assert tool_call.function.name == "get_weather"
      arguments = Jason.decode!(tool_call.function.arguments)
      assert is_binary(arguments["location"])
      assert arguments["location"] != ""
    end
  end
end
