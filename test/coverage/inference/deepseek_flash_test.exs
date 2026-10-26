defmodule ReqLLM.Coverage.Inference.DeepSeekFlashTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.{Context, Response, StreamResponse}
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: :inference
  @moduletag model: "deepseek-v4.1-flash-1017"
  @moduletag timeout: 300_000

  @tag CompatibilityScenario.tag!(:basic)
  test "generates text and usage" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Reply with only DEEPSEEK_OK.",
               options("basic", temperature: 0.0)
             )

    assert Response.text(response) == "DEEPSEEK_OK"
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  @tag CompatibilityScenario.tag!(:streaming)
  test "streams text and usage" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "Reply with only DEEP_STREAM_OK.",
               options("streaming", temperature: 0.0)
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.text(response) == "DEEP_STREAM_OK"
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
               "What is 31 plus 12? Reply with only the number.",
               options("reasoning_basic", reasoning_effort: :low)
             )

    assert Response.text(response) == "43"

    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "What is 32 plus 12? Reply with only the number.",
               options("reasoning_streaming", reasoning_effort: :low)
             )

    assert {:ok, streamed} = StreamResponse.to_response(stream)
    assert Response.text(streamed) == "44"
  end

  @tag CompatibilityScenario.tag!(:tool_round_trip)
  test "returns a forced strict tool call and accepts its result" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Call multiply_numbers with a=6 and b=7.",
               options("tool_round_trip_1",
                 tools: [multiply_tool()],
                 tool_choice: %{type: "tool", name: "multiply_numbers"}
               )
             )

    assert [call] = Response.tool_calls(response)
    assert call.function.name == "multiply_numbers"
    assert ReqLLM.ToolCall.args_map(call) == %{"a" => 6, "b" => 7}

    context =
      Context.append(
        response.context,
        Context.tool_result(call.id, "multiply_numbers", "42")
      )

    assert {:ok, answer} =
             ReqLLM.generate_text(
               model(),
               context,
               options("tool_round_trip_2", tools: [multiply_tool()], tool_choice: "none")
             )

    assert Response.text(answer) =~ "42"
  end

  @tag CompatibilityScenario.tag!(:object_basic)
  test "generates a strict structured object" do
    assert {:ok, response} =
             ReqLLM.generate_object(
               model(),
               "Return status ready and count 7.",
               object_schema(),
               options("object")
             )

    assert Response.object(response) == %{"count" => 7, "status" => "ready"}
  end

  @tag CompatibilityScenario.tag!(:object_streaming)
  test "streams a strict structured object" do
    assert {:ok, stream} =
             ReqLLM.stream_object(
               model(),
               "Return status ready and count 8.",
               object_schema(),
               options("object_streaming")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.object(response) == %{"count" => 8, "status" => "ready"}
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

  @tag category: :core, scenario: "vision"
  test "accepts image input" do
    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC"
      )

    prompt = [
      Context.user([
        ReqLLM.Message.ContentPart.text(
          "What is the dominant color in this image? Reply with one word."
        ),
        ReqLLM.Message.ContentPart.image(image, "image/png")
      ])
    ]

    assert {:ok, response} = ReqLLM.generate_text(model(), prompt, options("vision"))
    assert Response.text(response) =~ ~r/red/i
  end

  defp model do
    ReqLLM.model!(%{
      provider: :inference,
      id: "deepseek-v4.1-flash-1017",
      capabilities: %{
        chat: true,
        reasoning: %{enabled: true},
        tools: %{enabled: true, streaming: true, strict: true},
        json: %{native: true, schema: true, strict: true},
        streaming: %{text: true, tool_calls: true}
      },
      modalities: %{input: [:text, :image], output: [:text]},
      limits: %{context: 1_040_000, output: 393_216}
    })
  end

  defp options(fixture, extra \\ []) do
    opts =
      Keyword.merge(
        [
          max_tokens: 256,
          reasoning_effort: :none,
          max_retries: 0,
          provider_options: [
            inference_environment: "fixture",
            inference_task_id: "reqllm-deepseek-#{fixture}"
          ]
        ],
        extra
      )

    fixture_opts(fixture, opts)
  end

  defp object_schema do
    [
      status: [type: :string, required: true],
      count: [type: :integer, required: true]
    ]
  end

  defp multiply_tool do
    ReqLLM.Tool.new!(
      name: "multiply_numbers",
      description: "Multiply two integers",
      parameter_schema: [
        a: [type: :integer, required: true],
        b: [type: :integer, required: true]
      ],
      strict: true,
      callback: fn %{a: a, b: b} -> {:ok, a * b} end
    )
  end
end
