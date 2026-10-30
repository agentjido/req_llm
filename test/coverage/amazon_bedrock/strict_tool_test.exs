defmodule ReqLLM.Coverage.AmazonBedrock.StrictToolTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @runtime_model "amazon_bedrock:eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  @mantle_model %{provider: :amazon_bedrock, id: "anthropic.claude-haiku-4-5"}

  @routes [
    converse: {@runtime_model, [use_converse: true]},
    invoke: {@runtime_model, [use_converse: false]},
    mantle: {@mantle_model, [endpoint: :mantle]}
  ]

  defp weather_tool do
    ReqLLM.Tool.new!(
      name: "get_weather",
      description: "Get the current weather for a location",
      parameter_schema: [
        location: [type: :string, required: true, doc: "City and country"],
        unit: [type: {:in, ["celsius", "fahrenheit"]}, required: true, doc: "Temperature unit"]
      ],
      strict: true,
      callback: fn _args -> {:ok, "sunny"} end
    )
  end

  for {route, {model, provider_options}} <- @routes do
    @model model
    @provider_options provider_options

    test "#{route}: holds a strict tool call to its schema" do
      opts =
        fixture_opts("#{unquote(route)}_strict_tool",
          max_tokens: 256,
          tools: [weather_tool()],
          tool_choice: %{type: "tool", name: "get_weather"},
          provider_options: [region: "eu-west-1"] ++ @provider_options
        )

      {:ok, response} =
        ReqLLM.generate_text(@model, "What's the weather in Lyon, in Celsius?", opts)

      assert [call] = ReqLLM.Response.tool_calls(response)
      assert call.function.name == "get_weather"

      args = ReqLLM.ToolCall.args_map(call)
      assert Enum.sort(Map.keys(args)) == ["location", "unit"]
      assert args["unit"] == "celsius"
    end
  end
end
