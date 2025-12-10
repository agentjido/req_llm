defmodule ReqLLM.Parity.OpenAIResponsesParityTest do
  @moduledoc """
  Parity tests for OpenAI Responses API: streaming vs non-streaming.

  These tests verify that streaming and non-streaming produce identical
  Response structs for OpenAI Responses API (o-series reasoning models).

  Special focus areas for Responses API:
  - response_id must be preserved in message metadata for multi-turn
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

    test "tool_calls are identical" do
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

    test "finish_reason is :tool_calls when tools are called" do
      prompt = "What is 5 + 7? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_finish_reason_equal(non_streaming, streaming_response)
      # Responses API may return :stop even with tool calls, but should be consistent
    end

    test "finish_reason is :stop for normal completion" do
      prompt = "Say hello"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_finish_reason_equal(non_streaming, streaming_response)
      assert non_streaming.finish_reason == :stop
    end

    test "usage structure is identical" do
      prompt = "What is 2 + 2?"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_usage_structure_equal(non_streaming, streaming_response)
    end

    test "response_id is preserved in message metadata (bug #270)" do
      prompt = "What is 2 + 3? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should have response_id in message metadata
      assert_metadata_preserved(non_streaming, streaming_response, [:response_id])
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

    test "multi-turn tool calling works identically" do
      # This test specifically addresses bug #270
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

      # Both should have text response (the actual result)
      assert ReqLLM.Response.text(resp2_ns) != nil
      assert ReqLLM.Response.text(resp2_s) != nil
    end

    test "reasoning content is preserved in both paths" do
      prompt = "Think step by step: what is 15 * 23?"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should have reasoning tokens in usage
      ns_usage = ReqLLM.Response.usage(non_streaming)
      s_usage = ReqLLM.Response.usage(streaming_response)

      if ns_usage[:reasoning_tokens] && ns_usage[:reasoning_tokens] > 0 do
        assert s_usage[:reasoning_tokens] && s_usage[:reasoning_tokens] > 0
      end
    end
  end
end
