defmodule ReqLLM.Parity.OpenAIResponsesParityTest do
  @moduledoc """
  Parity tests for OpenAI Responses API: streaming vs non-streaming.

  These tests verify that streaming and non-streaming produce semantically
  equivalent Response structs for OpenAI Responses API (o-series reasoning models).

  Special focus areas for Responses API:
  - finish_reason correction when tool calls are present
  - Stateless multi-turn using previous_response_id
  - Reasoning content preservation
  """

  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :openai_responses
  @moduletag :integration

  # Use an o-series model that uses Responses API
  @model "openai:o4-mini"

  describe "streaming vs non-streaming parity" do
    @describetag :integration
    @describetag timeout: 120_000

    test "tool_calls structure is equivalent" do
      prompt = "What is 2 + 3? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_tool_calls_equal(non_streaming, streaming_response)
      assert_tool_calls_are_structs(non_streaming)
      assert_tool_calls_are_structs(streaming_response)
    end

    test "finish_reason is consistent between streaming and non-streaming" do
      prompt = "What is 5 + 7? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should have consistent finish_reason
      assert_finish_reason_equal(non_streaming, streaming_response)

      # With tool calls, should be :tool_calls
      assert non_streaming.finish_reason == :tool_calls,
             "Expected :tool_calls, got #{inspect(non_streaming.finish_reason)}"
    end

    test "finish_reason is :stop for normal completion" do
      prompt = "Say hello"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_finish_reason_equal(non_streaming, streaming_response)
      assert non_streaming.finish_reason == :stop
    end

    test "text responses are semantically equivalent" do
      prompt = "What is 2 + 2? Just give the number."

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should contain the answer 4
      assert_text_semantically_equal(non_streaming, streaming_response,
        type: :math,
        expected_values: [4]
      )
    end

    test "usage data is present in both" do
      prompt = "What is 2 + 2?"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_usage_valid(non_streaming, streaming_response)
    end

    test "context is valid for next turn after tool call" do
      prompt = "What is 2 + 3? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_context_valid_for_next_turn(non_streaming)
      assert_context_valid_for_next_turn(streaming_response)
    end

    test "multi-turn tool calling works" do
      prompt = "What is 2 + 3? Use the add tool."
      tools = [add_tool()]

      # Non-streaming multi-turn
      {:ok, resp1_ns} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      tool_calls_ns = ReqLLM.Response.tool_calls(resp1_ns)
      ctx_ns = ReqLLM.Context.execute_and_append_tools(resp1_ns.context, tool_calls_ns, tools)
      {:ok, resp2_ns} = ReqLLM.generate_text(@model, ctx_ns)

      # Streaming multi-turn
      {:ok, stream1} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, resp1_s} = ReqLLM.StreamResponse.process_stream(stream1)
      tool_calls_s = ReqLLM.Response.tool_calls(resp1_s)
      ctx_s = ReqLLM.Context.execute_and_append_tools(resp1_s.context, tool_calls_s, tools)
      {:ok, resp2_s} = ReqLLM.generate_text(@model, ctx_s)

      # Both should complete successfully
      assert resp2_ns.finish_reason == :stop
      assert resp2_s.finish_reason == :stop

      # Both should have text response containing the answer (5)
      assert_text_semantically_equal(resp2_ns, resp2_s, type: :math, expected_values: [5])
    end

    test "reasoning content is preserved in both paths" do
      prompt = "Think step by step: what is 15 * 23?"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should have reasoning tokens in usage (o-series models do internal reasoning)
      ns_usage = ReqLLM.Response.usage(non_streaming)
      s_usage = ReqLLM.Response.usage(streaming_response)

      # If non-streaming has reasoning tokens, streaming should too
      if ns_usage[:reasoning_tokens] && ns_usage[:reasoning_tokens] > 0 do
        assert s_usage[:reasoning_tokens] && s_usage[:reasoning_tokens] > 0,
               "Non-streaming has reasoning tokens but streaming doesn't"
      end

      # Both should contain the correct answer (345)
      assert_text_semantically_equal(non_streaming, streaming_response,
        type: :math,
        expected_values: [345]
      )
    end

    test "response_id is present in message metadata for both paths" do
      # response_id is critical for multi-turn conversations with the Responses API
      prompt = "Say hello"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Non-streaming should have response_id in message metadata
      ns_response_id = non_streaming.message.metadata[:response_id]

      assert is_binary(ns_response_id) and ns_response_id != "",
             "Non-streaming response should have response_id in message.metadata, got: #{inspect(non_streaming.message.metadata)}"

      # Streaming should also have response_id in message metadata
      s_response_id = streaming_response.message.metadata[:response_id]

      assert is_binary(s_response_id) and s_response_id != "",
             "Streaming response should have response_id in message.metadata, got: #{inspect(streaming_response.message.metadata)}"

      # Both should start with "resp_" prefix
      assert String.starts_with?(ns_response_id, "resp_"),
             "Non-streaming response_id should start with 'resp_', got: #{ns_response_id}"

      assert String.starts_with?(s_response_id, "resp_"),
             "Streaming response_id should start with 'resp_', got: #{s_response_id}"
    end
  end
end
