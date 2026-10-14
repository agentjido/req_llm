defmodule ReqLLM.Coverage.Reflection.ComprehensiveTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.{Context, Response, StreamResponse}

  @moduletag :coverage
  @moduletag provider: :reflection
  @moduletag model: "Beam-1.0-501B-A23B"
  @moduletag timeout: 300_000

  defp model do
    ReqLLM.model!(%{provider: :reflection, id: "Beam-1.0-501B-A23B"})
  end

  defp options(fixture, extra \\ []) do
    fixture_opts(fixture, [max_tokens: 2048, reasoning_effort: :low, max_retries: 0] ++ extra)
  end

  defp assert_reasoning(response) do
    assert Enum.any?(response.message.content, fn
             %{type: :thinking, text: text} -> is_binary(text) and text != ""
             _ -> false
           end)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:basic)
  test "generates text and preserves reasoning for another turn" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "What is 2 + 4? Answer with one number.",
               options("basic")
             )

    assert Response.text(response) =~ "6"
    assert_reasoning(response)
    assert response.usage.input_tokens > 0
    assert response.usage.reasoning_tokens > 0

    context = Context.append(response.context, Context.user("Add 1. Answer with one number."))
    assert {:ok, followup} = ReqLLM.generate_text(model(), context, options("context_append"))
    assert Response.text(followup) =~ "7"
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:streaming)
  test "streams text and preserves reasoning for another turn" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "What is 3 + 5? Answer with one number.",
               options("streaming")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.text(response) =~ "8"
    assert_reasoning(response)

    context = Context.append(response.context, Context.user("Add 1. Answer with one number."))

    assert {:ok, followup} =
             ReqLLM.generate_text(model(), context, options("stream_context_append"))

    assert Response.text(followup) =~ "9"
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_basic)
  test "generates an object with a native JSON schema" do
    assert {:ok, response} =
             ReqLLM.generate_object(
               model(),
               "Return greeting set to hello.",
               [greeting: [type: :string, required: true]],
               options("object_basic")
             )

    assert Response.object(response) == %{"greeting" => "hello"}
    assert_reasoning(response)

    context =
      Context.append(response.context, Context.user("Reply with the greeting as plain text."))

    assert {:ok, followup} =
             ReqLLM.generate_text(model(), context, options("object_context_append"))

    assert Response.text(followup) =~ "hello"
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_streaming)
  test "streams an object with a native JSON schema" do
    assert {:ok, stream} =
             ReqLLM.stream_object(
               model(),
               "Return greeting set to hello.",
               [greeting: [type: :string, required: true]],
               options("object_streaming")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.object(response) == %{"greeting" => "hello"}
    assert_reasoning(response)

    context =
      Context.append(response.context, Context.user("Reply with the greeting as plain text."))

    assert {:ok, followup} =
             ReqLLM.generate_text(model(), context, options("stream_object_context_append"))

    assert Response.text(followup) =~ "hello"
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:tool_round_trip)
  test "calls a tool and uses its result with reasoning intact" do
    tool = weather_tool()
    choice = %{type: "function", function: %{name: "weather"}}

    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Use the weather tool for Paris.",
               options("tool_round_trip_1", tools: [tool], tool_choice: choice)
             )

    assert_reasoning(response)
    assert [call] = response.message.tool_calls
    assert call.function.name == "weather"

    context = Context.append(response.context, Context.tool_result(call.id, "sunny, 18 C"))

    assert {:ok, answer} =
             ReqLLM.generate_text(
               model(),
               context,
               options("tool_round_trip_2", tools: [tool], tool_choice: "none")
             )

    assert Response.text(answer) =~ "18"
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:streaming)
  test "streams tool arguments and preserves reasoning" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "Use the weather tool for Paris.",
               options("tool_streaming", tools: [weather_tool()], tool_choice: "required")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert_reasoning(response)
    assert [call] = response.message.tool_calls
    assert call.function.name == "weather"
    assert ReqLLM.ToolCall.args_map(call)["city"] == "Paris"
  end

  defp weather_tool do
    ReqLLM.Tool.new!(
      name: "weather",
      description: "Get the weather for a city.",
      parameter_schema: [city: [type: :string, required: true]],
      callback: fn _ -> {:ok, "sunny, 18 C"} end,
      strict: true
    )
  end
end
