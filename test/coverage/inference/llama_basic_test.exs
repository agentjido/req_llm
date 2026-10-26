defmodule ReqLLM.Coverage.Inference.LlamaBasicTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.{Context, Response, StreamResponse}
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: :inference
  @moduletag model: "llama-3.2-1b-instruct"
  @moduletag timeout: 300_000

  @tag CompatibilityScenario.tag!(:basic)
  test "generates basic text" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Say hello in one short sentence.",
               options("basic")
             )

    assert is_binary(Response.text(response))
    assert Response.text(response) != ""
  end

  @tag CompatibilityScenario.tag!(:streaming)
  test "streams basic text" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               model(),
               "Say hello in one short sentence.",
               options("streaming")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert is_binary(Response.text(response))
    assert Response.text(response) != ""
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

  @tag CompatibilityScenario.tag!(:context_append)
  test "continues a conversation" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               model(),
               "Remember the code word ORANGE. Reply with remembered.",
               options("context_append_1")
             )

    context = Context.append(response.context, Context.user("What was the code word?"))

    assert {:ok, answer} =
             ReqLLM.generate_text(
               model(),
               context,
               options("context_append_2")
             )

    assert Response.text(answer) =~ ~r/orange/i
  end

  defp model do
    ReqLLM.model!(%{
      provider: :inference,
      id: "llama-3.2-1b-instruct",
      capabilities: %{
        chat: true,
        reasoning: %{enabled: false},
        tools: %{enabled: false, streaming: false, strict: false},
        json: %{native: true, schema: true, strict: true},
        streaming: %{text: true, tool_calls: false}
      },
      modalities: %{input: [:text], output: [:text]},
      limits: %{context: 60_000, output: 60_000}
    })
  end

  defp options(fixture, extra \\ []) do
    opts =
      Keyword.merge(
        [
          max_tokens: 128,
          temperature: 0.0,
          max_retries: 0,
          provider_options: [
            inference_environment: "fixture",
            inference_task_id: "reqllm-llama-#{fixture}"
          ]
        ],
        extra
      )

    fixture_opts(fixture, opts)
  end
end
