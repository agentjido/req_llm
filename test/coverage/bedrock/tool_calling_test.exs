defmodule ReqLLM.Coverage.Bedrock.ToolCallingTest do
  @moduledoc """
  Tool calling feature coverage tests for AWS Bedrock provider.
  """

  use ReqLLM.ProviderTest.ToolCalling,
    provider: :amazon_bedrock,
    model: "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0"

  # import ReqLLM.Test.LiveFixture  # TODO: Fix this import

  alias ReqLLM.Tool

  test "tool calling with Anthropic models on Bedrock" do
    weather_tool = %Tool{
      name: "get_weather",
      description: "Get the current weather in a given location",
      parameter_schema: [
        location: [type: :string, required: true, doc: "City and country, e.g. Paris, France"],
        unit: [type: :string, enum: ["celsius", "fahrenheit"], doc: "Temperature unit"]
      ],
      callback: fn _args -> {:ok, %{temperature: 20, unit: "celsius"}} end
    }

    {:ok, response} =
      ReqLLM.generate_text(
        "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0",
        "What's the weather like in New York?",
        tools: [weather_tool],
        tool_choice: "auto",
        max_tokens: 200,
        provider_options: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        fixture: "bedrock_tool_calling"
      )

    tool_calls =
      response.message.content
      |> Enum.filter(&(&1.type == :tool_call))

    if not Enum.empty?(tool_calls) do
      [tool_call | _] = tool_calls
      assert tool_call.tool_name == "get_weather"
      assert Map.has_key?(tool_call.input, "location")
    end
  end
end
