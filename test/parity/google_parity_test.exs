defmodule ReqLLM.Parity.GoogleParityTest do
  @moduledoc """
  Parity tests for Google Gemini: streaming vs non-streaming.

  These tests verify that streaming and non-streaming produce semantically
  equivalent Response structs for Google Gemini models.

  Special focus areas for Google:
  - finish_reason must be :tool_calls when functionCall present (bug #271)
  - Google returns "STOP" even when function calls are made
  """

  use ExUnit.Case, async: true

  import ReqLLM.Parity.TestHelper

  @moduletag :parity
  @moduletag :google
  @moduletag :integration

  @model "google:gemini-2.0-flash"

  describe "streaming vs non-streaming parity" do
    @describetag :integration
    @describetag timeout: 60_000

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

    test "finish_reason is :tool_calls when tools are called (bug #271)" do
      # This test specifically addresses bug #271
      # Google returns "STOP" but should be normalized to :tool_calls when
      # functionCall parts are present
      prompt = "What is 5 + 7? Use the add tool."
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should have :tool_calls finish_reason
      assert_finish_reason_equal(non_streaming, streaming_response)

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
      prompt = "What is the capital of France? Answer in one word."

      {:ok, non_streaming} = ReqLLM.generate_text(@model, prompt)

      {:ok, streaming} = ReqLLM.stream_text(@model, prompt)
      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      # Both should mention Paris
      assert_text_semantically_equal(non_streaming, streaming_response,
        type: :contains,
        expected_terms: ["Paris"]
      )
    end

    test "usage data is present in both" do
      prompt = "What is the capital of France?"

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

    test "tool-call responses have valid content structure" do
      prompt = "Add 10 and 20 using the add tool"
      tools = [add_tool()]

      {:ok, non_streaming} =
        ReqLLM.generate_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming} =
        ReqLLM.stream_text(@model, prompt, tools: tools, tool_choice: :required)

      {:ok, streaming_response} = ReqLLM.StreamResponse.process_stream(streaming)

      assert_tool_call_content_valid(non_streaming)
      assert_tool_call_content_valid(streaming_response)
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

      # Both should have text response containing the answer
      assert ReqLLM.Response.text(resp2_ns) != nil
      assert ReqLLM.Response.text(resp2_s) != nil
    end

    @tag :skip
    test "thinking content is preserved in both paths (Gemini 2.5)" do
      # Skip for now - needs Gemini 2.5 with thinking enabled
      :ok
    end
  end
end
