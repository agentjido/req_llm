defmodule ReqLLM.Streaming.SSETest do
  use ExUnit.Case, async: true

  alias ReqLLM.Streaming.SSE

  describe "accumulate_and_parse/2" do
    test "parses complete SSE event in single chunk" do
      chunk = ~s(data: {"message": "hello"}\n\n)
      buffer = ""

      {events, remaining} = SSE.accumulate_and_parse(chunk, buffer)

      assert length(events) == 1
      assert [%{data: ~s({"message": "hello"})}] = events
      assert remaining == ""
    end

    test "handles incomplete event across multiple chunks" do
      # First chunk contains incomplete event
      chunk1 = "data: {\"partial"
      {events1, buffer1} = SSE.accumulate_and_parse(chunk1, "")

      assert events1 == []
      assert buffer1 == "data: {\"partial"

      # Second chunk completes the event
      chunk2 = " event\"}\n\n"
      {events2, buffer2} = SSE.accumulate_and_parse(chunk2, buffer1)

      assert length(events2) == 1
      assert [%{data: "{\"partial event\"}"}] = events2
      assert buffer2 == ""
    end

    test "handles multiple events in single chunk" do
      chunk = ~s(data: {"first": 1}\n\ndata: {"second": 2}\n\n)
      {events, remaining} = SSE.accumulate_and_parse(chunk, "")

      assert length(events) == 2
      assert [%{data: "{\"first\": 1}"}, %{data: "{\"second\": 2}"}] = events
      assert remaining == ""
    end

    test "preserves incomplete data at end of chunk" do
      chunk = "data: {\"complete\"}\n\ndata: {\"incomplete"
      {events, remaining} = SSE.accumulate_and_parse(chunk, "")

      assert length(events) == 1
      assert [%{data: "{\"complete\"}"}] = events
      assert remaining == "data: {\"incomplete"
    end

    test "handles mixed complete and incomplete events with buffer" do
      # Start with some buffered incomplete data
      buffer = "data: {\"start"
      chunk = ~s(ed"}\n\ndata: {"new"}\n\ndata: {"partial)

      {events, new_buffer} = SSE.accumulate_and_parse(chunk, buffer)

      assert length(events) == 2
      assert [%{data: "{\"started\"}"}, %{data: "{\"new\"}"}] = events
      assert new_buffer == "data: {\"partial"
    end

    test "handles empty chunks" do
      {events, remaining} = SSE.accumulate_and_parse("", "some buffer")
      assert events == []
      assert remaining == "some buffer"
    end

    test "handles events with id and event type" do
      chunk = ~s(id: 123\nevent: delta\ndata: {"text": "hi"}\n\n)
      {events, remaining} = SSE.accumulate_and_parse(chunk, "")

      assert length(events) == 1
      assert [%{id: "123", event: "delta", data: ~s({"text": "hi"})}] = events
      assert remaining == ""
    end
  end

  describe "process_sse_event/1" do
    test "decodes valid JSON data" do
      event = %{data: ~s({"message": "hello", "type": "text"})}

      result = SSE.process_sse_event(event)

      assert %{data: %{"message" => "hello", "type" => "text"}} = result
    end

    test "leaves invalid JSON unchanged" do
      event = %{data: "invalid json {"}

      result = SSE.process_sse_event(event)

      assert result == event
    end

    test "handles non-string data unchanged" do
      event = %{data: nil}
      result = SSE.process_sse_event(event)
      assert result == event

      event = %{data: 123}
      result = SSE.process_sse_event(event)
      assert result == event
    end

    test "preserves other event fields during JSON decode" do
      event = %{id: "123", event: "delta", data: ~s({"text": "hi"})}

      result = SSE.process_sse_event(event)

      assert %{
               id: "123",
               event: "delta",
               data: %{"text" => "hi"}
             } = result
    end

    test "handles special SSE data values" do
      # [DONE] marker common in OpenAI streams
      event = %{data: "[DONE]"}
      result = SSE.process_sse_event(event)
      assert result == event

      # Empty data
      event = %{data: ""}
      result = SSE.process_sse_event(event)
      assert result == event
    end

    test "handles complex nested JSON" do
      json_data = """
      {
        "choices": [
          {
            "delta": {
              "content": "Hello world"
            },
            "finish_reason": null
          }
        ]
      }
      """

      event = %{data: json_data}
      result = SSE.process_sse_event(event)

      assert %{data: %{"choices" => [%{"delta" => %{"content" => "Hello world"}}]}} = result
    end
  end

  describe "parse_sse_stream/1" do
    test "parses stream of chunks with boundary splits" do
      chunks = [
        "data: {\"text\":",
        ~s( "hello"}\n\ndata: {"text": "world"}\n\n),
        "data: [DONE]\n\n"
      ]

      events =
        chunks
        |> SSE.parse_sse_stream()
        |> Enum.to_list()

      assert length(events) == 3

      assert [
               %{data: %{"text" => "hello"}},
               %{data: %{"text" => "world"}},
               %{data: "[DONE]"}
             ] = events
    end

    test "processes valid SSE events with invalid JSON data" do
      stream = [
        "data: {\"valid\": true}\n\n",
        # Valid SSE event but invalid JSON
        "data: invalid json format\n\n",
        ~s(data: {"another": "valid"}\n\n)
      ]

      events =
        stream
        |> SSE.parse_sse_stream()
        |> Enum.to_list()

      # Should get all 3 events (invalid JSON preserved as string)
      assert length(events) == 3

      assert [
               %{data: %{"valid" => true}},
               # Invalid JSON preserved as string
               %{data: "invalid json format"},
               %{data: %{"another" => "valid"}}
             ] = events
    end

    test "handles empty stream" do
      events =
        []
        |> SSE.parse_sse_stream()
        |> Enum.to_list()

      assert events == []
    end
  end

  describe "parse_sse_binary/1" do
    test "parses complete SSE response" do
      binary = """
      data: {"message": "hello"}

      data: {"message": "world"}

      data: [DONE]

      """

      events = SSE.parse_sse_binary(binary)

      assert length(events) == 3

      assert [
               %{data: %{"message" => "hello"}},
               %{data: %{"message" => "world"}},
               %{data: "[DONE]"}
             ] = events
    end

    test "handles binary with mixed valid/invalid JSON" do
      binary = """
      data: {"valid": true}

      data: invalid json

      data: {"also": "valid"}

      """

      events = SSE.parse_sse_binary(binary)

      assert length(events) == 3

      assert [
               %{data: %{"valid" => true}},
               %{data: "invalid json"},
               %{data: %{"also" => "valid"}}
             ] = events
    end

    test "handles empty binary" do
      events = SSE.parse_sse_binary("")
      assert events == []
    end

    test "handles binary with SSE metadata" do
      binary = """
      id: msg-1
      event: delta
      data: {"content": "Hello"}

      id: msg-2
      event: done
      data: [DONE]

      """

      events = SSE.parse_sse_binary(binary)

      assert length(events) == 2

      assert [
               %{id: "msg-1", event: "delta", data: %{"content" => "Hello"}},
               %{id: "msg-2", event: "done", data: "[DONE]"}
             ] = events
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed SSE format gracefully" do
      # Missing double newline
      chunk = "data: {\"incomplete\": true}"
      {events, buffer} = SSE.accumulate_and_parse(chunk, "")

      assert events == []
      assert buffer == chunk
    end

    test "handles very large JSON payloads" do
      large_data = %{"content" => String.duplicate("a", 10_000)}
      large_json = Jason.encode!(large_data)
      chunk = "data: #{large_json}\n\n"

      {events, remaining} = SSE.accumulate_and_parse(chunk, "")

      assert length(events) == 1
      processed = SSE.process_sse_event(hd(events))
      assert %{data: ^large_data} = processed
      assert remaining == ""
    end

    test "handles Unicode content in JSON" do
      unicode_content = ~s({"message": "Hello 👋 世界"})
      chunk = "data: #{unicode_content}\n\n"

      {events, _} = SSE.accumulate_and_parse(chunk, "")
      processed = SSE.process_sse_event(hd(events))

      assert %{data: %{"message" => "Hello 👋 世界"}} = processed
    end

    test "preserves raw data when JSON decode fails" do
      chunk = "data: {\"unclosed\": \"quote}\n\n"

      {events, _} = SSE.accumulate_and_parse(chunk, "")
      processed = SSE.process_sse_event(hd(events))

      # Should preserve original malformed JSON string
      assert %{data: "{\"unclosed\": \"quote}"} = processed
    end
  end
end
