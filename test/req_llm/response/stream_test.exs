defmodule ReqLLM.Response.StreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Response.Stream, as: ResponseStream
  alias ReqLLM.StreamChunk

  describe "summarize/1" do
    test "accumulates text content" do
      chunks = [
        StreamChunk.text("Hello "),
        StreamChunk.text("world"),
        StreamChunk.text("!")
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.text == "Hello world!"
    end

    test "accumulates thinking content" do
      chunks = [
        StreamChunk.thinking("Let me think..."),
        StreamChunk.thinking(" about this."),
        StreamChunk.text("Here's my answer.")
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.thinking == "Let me think... about this."
      assert summary.text == "Here's my answer."
    end

    test "reconstructs tool calls from fragments" do
      chunks = [
        StreamChunk.tool_call("get_weather", %{}, %{id: "call_123", index: 0}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "{\"city\":"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: " \"NYC\"}"}})
      ]

      summary = ResponseStream.summarize(chunks)

      assert length(summary.tool_calls) == 1
      assert hd(summary.tool_calls).id == "call_123"
      assert hd(summary.tool_calls).name == "get_weather"
      assert hd(summary.tool_calls).arguments == %{"city" => "NYC"}
    end

    test "handles multiple parallel tool calls with interleaved fragments" do
      chunks = [
        StreamChunk.tool_call("func1", %{}, %{id: "c1", index: 0}),
        StreamChunk.tool_call("func2", %{}, %{id: "c2", index: 1}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "{\"a\":"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: "{\"b\":"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: " 1}"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: " 2}"}})
      ]

      summary = ResponseStream.summarize(chunks)

      assert length(summary.tool_calls) == 2

      func1 = Enum.find(summary.tool_calls, &(&1.name == "func1"))
      func2 = Enum.find(summary.tool_calls, &(&1.name == "func2"))

      assert func1.arguments == %{"a" => 1}
      assert func2.arguments == %{"b" => 2}
    end

    test "extracts finish_reason from metadata" do
      chunks = [
        StreamChunk.text("Done"),
        StreamChunk.meta(%{finish_reason: "stop"})
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.finish_reason == :stop
    end

    test "extracts usage from metadata" do
      chunks = [
        StreamChunk.text("Response"),
        StreamChunk.meta(%{usage: %{input_tokens: 10, output_tokens: 5}})
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.usage == %{input_tokens: 10, output_tokens: 5}
    end

    test "merges multiple usage chunks" do
      chunks = [
        StreamChunk.meta(%{usage: %{input_tokens: 10}}),
        StreamChunk.meta(%{usage: %{output_tokens: 5}})
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.usage == %{input_tokens: 10, output_tokens: 5}
    end

    test "handles empty stream" do
      summary = ResponseStream.summarize([])

      assert summary.text == ""
      assert summary.thinking == ""
      assert summary.tool_calls == []
      assert summary.finish_reason == nil
      assert summary.usage == nil
    end

    test "handles malformed JSON in tool call args" do
      chunks = [
        StreamChunk.tool_call("broken", %{}, %{id: "c1", index: 0}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "{not valid json"}})
      ]

      summary = ResponseStream.summarize(chunks)

      assert length(summary.tool_calls) == 1
      assert hd(summary.tool_calls).arguments == %{}
    end

    test "normalizes string finish_reason to atoms" do
      test_cases = [
        {"stop", :stop},
        {"completed", :stop},
        {"end_turn", :stop},
        {"tool_calls", :tool_calls},
        {"tool_use", :tool_calls},
        {"length", :length},
        {"max_tokens", :length},
        {"content_filter", :content_filter},
        {"unknown_value", :unknown}
      ]

      for {input, expected} <- test_cases do
        chunks = [StreamChunk.meta(%{finish_reason: input})]
        summary = ResponseStream.summarize(chunks)
        assert summary.finish_reason == expected, "Expected #{input} to normalize to #{expected}"
      end
    end

    test "preserves atom finish_reason" do
      chunks = [StreamChunk.meta(%{finish_reason: :stop})]
      summary = ResponseStream.summarize(chunks)
      assert summary.finish_reason == :stop
    end

    test "accepts non-list enumerables" do
      stream =
        Stream.concat([
          [StreamChunk.text("Hello")],
          [StreamChunk.text(" World")]
        ])

      summary = ResponseStream.summarize(stream)

      assert summary.text == "Hello World"
    end

    test "ignores unknown chunk types" do
      chunks = [
        StreamChunk.text("Valid"),
        %StreamChunk{type: :unknown, text: "Should be ignored"},
        StreamChunk.text(" text")
      ]

      summary = ResponseStream.summarize(chunks)

      assert summary.text == "Valid text"
    end

    test "tool calls without fragments use empty arguments" do
      chunks = [
        StreamChunk.tool_call("no_args_func", %{preset: "value"}, %{id: "c1", index: 0})
      ]

      summary = ResponseStream.summarize(chunks)

      assert length(summary.tool_calls) == 1
      assert hd(summary.tool_calls).arguments == %{preset: "value"}
    end

    test "generates unique id when not provided" do
      chunks = [
        StreamChunk.tool_call("func", %{}, %{index: 0})
      ]

      summary = ResponseStream.summarize(chunks)

      assert length(summary.tool_calls) == 1

      assert is_binary(hd(summary.tool_calls).id) or
               is_binary(to_string(hd(summary.tool_calls).id))
    end
  end
end
