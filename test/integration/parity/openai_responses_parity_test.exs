defmodule ReqLLM.Parity.OpenAIResponsesParityTest do
  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :openai_responses
  @moduletag :integration
  @model "openai:o4-mini"

  parity_contract(
    model: @model,
    timeout: 120_000,
    text_prompt: "What is 2 + 2? Just give the number.",
    text_opts: [type: :math, expected_values: [4]]
  )

  describe "Responses API parity" do
    @describetag timeout: 120_000

    test "reasoning content is present in both paths" do
      {non_streaming, streaming} =
        response_pair!(@model, "Think step by step: what is 15 * 23?")

      non_streaming_usage = ReqLLM.Response.usage(non_streaming)
      streaming_usage = ReqLLM.Response.usage(streaming)

      if is_integer(non_streaming_usage[:reasoning_tokens]) and
           non_streaming_usage[:reasoning_tokens] > 0 do
        assert streaming_usage[:reasoning_tokens] > 0
      end

      assert_text_semantically_equal(non_streaming, streaming,
        type: :math,
        expected_values: [345]
      )
    end

    test "response IDs are present in both paths" do
      {non_streaming, streaming} = response_pair!(@model, "Say hello")

      non_streaming_id = non_streaming.message.metadata[:response_id]
      streaming_id = streaming.message.metadata[:response_id]

      assert is_binary(non_streaming_id)
      assert is_binary(streaming_id)
      assert String.starts_with?(non_streaming_id, "resp_")
      assert String.starts_with?(streaming_id, "resp_")
    end
  end
end
