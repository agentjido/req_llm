defmodule ReqLLM.Parity.AnthropicParityTest do
  @moduledoc """
  Parity tests for Anthropic: streaming vs non-streaming.

  These tests verify that streaming and non-streaming produce identical
  Response structs for Anthropic Claude models.

  Special focus areas for Anthropic:
  - Tool-call-only responses must have non-empty content (API requirement)
  - finish_reason mapping from "tool_use" to :tool_calls
  - Thinking content preservation
  """

  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :anthropic
  @moduletag :integration

  @model "anthropic:claude-3-haiku-20240307"

  describe "streaming vs non-streaming parity" do
    @describetag :integration
    @describetag timeout: 60_000

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
      assert non_streaming.finish_reason == :tool_calls
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
      prompt = "What is the capital of France?"

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_usage_structure_equal(non_streaming, streaming_response)
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

    test "tool-call-only responses have non-empty content (Anthropic requirement)" do
      # This test specifically addresses bug #269
      prompt = "Add 10 and 20 using the add tool. Just call the tool, don't say anything."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both must have valid content for Anthropic
      assert_tool_call_content_valid(non_streaming)
      assert_tool_call_content_valid(streaming_response)

      # Anthropic-specific: content must not be empty list when tool_calls present
      if non_streaming.message.tool_calls && non_streaming.message.tool_calls != [] do
        # Content can be [] for other providers, but for Anthropic this would fail
        # The ResponseBuilder should ensure at least an empty text part
        assert is_list(non_streaming.message.content)
      end

      if streaming_response.message.tool_calls && streaming_response.message.tool_calls != [] do
        assert is_list(streaming_response.message.content)
      end
    end

    test "multi-turn tool calling works identically" do
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

    @tag :skip
    test "thinking content is preserved in both paths" do
      # Skip for now as Haiku doesn't support extended thinking
      # Would need claude-3-5-sonnet or similar with thinking enabled
      :ok
    end
  end
end
