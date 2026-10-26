defmodule ReqLLM.Coverage.Inference.ComprehensiveTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.{Context, Response, StreamResponse}
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: :inference
  @moduletag model: "gpt-5-nano"
  @moduletag timeout: 300_000

  @tag CompatibilityScenario.tag!(:basic)
  test "generates text" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Reply with only INFERENCE_OK.",
               options("basic", temperature: 0.0)
             )

    assert Response.text(response) == "INFERENCE_OK"
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  @tag CompatibilityScenario.tag!(:streaming)
  test "streams text and usage" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "Reply with only STREAM_OK.",
               options("streaming", temperature: 0.0)
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.text(response) == "STREAM_OK"
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  @tag CompatibilityScenario.tag!(:usage)
  test "returns token usage" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Reply with one word.",
               options("usage")
             )

    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0

    assert response.usage.total_tokens ==
             response.usage.input_tokens + response.usage.output_tokens
  end

  @tag CompatibilityScenario.tag!(:reasoning)
  test "accepts reasoning effort for request and stream responses" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "What is 17 plus 25? Reply with only the number.",
               options("reasoning_basic", reasoning_effort: :low)
             )

    assert Response.text(response) == "42"
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0

    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "What is 18 plus 25? Reply with only the number.",
               options("reasoning_streaming", reasoning_effort: :low)
             )

    assert {:ok, streamed} = StreamResponse.to_response(stream)
    assert Response.text(streamed) == "43"
  end

  @tag CompatibilityScenario.tag!(:tool_round_trip)
  test "returns a forced strict tool call and accepts its result" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Call add_numbers with a=2 and b=3.",
               options("tool_round_trip_1",
                 tools: [add_tool()],
                 tool_choice: %{type: "tool", name: "add_numbers"}
               )
             )

    assert [call] = Response.tool_calls(response)
    assert call.function.name == "add_numbers"
    assert ReqLLM.ToolCall.args_map(call) == %{"a" => 2, "b" => 3}

    context =
      Context.append(
        response.context,
        Context.tool_result(call.id, "add_numbers", "5")
      )

    assert {:ok, answer} =
             ReqLLM.generate_text(
               model(),
               context,
               options("tool_round_trip_2", tools: [add_tool()], tool_choice: "none")
             )

    assert Response.text(answer) =~ "5"
  end

  @tag CompatibilityScenario.tag!(:object_basic)
  test "generates a strict structured object" do
    assert {:ok, response} =
             ReqLLM.generate_object(
               model(),
               "Return status ready and count 3.",
               [
                 status: [type: :string, required: true],
                 count: [type: :integer, required: true]
               ],
               options("object")
             )

    assert Response.object(response) == %{"count" => 3, "status" => "ready"}
  end

  @tag CompatibilityScenario.tag!(:object_streaming)
  test "streams a strict structured object" do
    assert {:ok, stream} =
             ReqLLM.stream_object(
               model(),
               "Return status ready and count 4.",
               [
                 status: [type: :string, required: true],
                 count: [type: :integer, required: true]
               ],
               options("object_streaming")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.object(response) == %{"count" => 4, "status" => "ready"}
  end

  @tag CompatibilityScenario.tag!(:token_limit)
  test "honors a small token limit" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Write a long list of numbers.",
               options("token_limit", max_tokens: 16)
             )

    assert response.usage.output_tokens <= 16
  end

  defp model do
    ReqLLM.model!(%{provider: :inference, id: "gpt-5-nano"})
  end

  defp options(fixture, extra \\ []) do
    opts =
      Keyword.merge(
        [
          max_tokens: 256,
          reasoning_effort: :minimal,
          max_retries: 0,
          provider_options: [
            inference_environment: "fixture",
            inference_task_id: "reqllm-#{fixture}"
          ]
        ],
        extra
      )

    fixture_opts(fixture, opts)
  end

  defp add_tool do
    ReqLLM.Tool.new!(
      name: "add_numbers",
      description: "Add two integers",
      parameter_schema: [
        a: [type: :integer, required: true],
        b: [type: :integer, required: true]
      ],
      strict: true,
      callback: fn %{a: a, b: b} -> {:ok, a + b} end
    )
  end
end
