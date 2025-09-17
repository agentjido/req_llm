defmodule ReqLLM.Providers.OpenAI.SSEToolCallTest do
  @moduledoc """
  Tests for OpenAI SSE streaming tool-call assembly.

  Validates the stateful assembly of tool calls across multiple SSE chunks,
  ensuring proper JSON argument accumulation and single emission per tool call.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.StreamChunk
  alias ReqLLM.Model

  describe "SSE tool-call assembly" do
    test "assembles single tool call across multiple chunks" do
      # Create mock SSE events simulating incremental tool call
      events = [
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "id" => "call_123", "function" => %{"name" => "get_weather"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => "{\"loc"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => "ation\": \"New"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => " York\", \"unit\":"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => " \"celsius\"}"}}
        ]}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)

      # Collect all chunks
      chunks = Enum.to_list(response.stream)

      # Should have exactly one tool_call chunk and one meta chunk
      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))
      meta_chunks = Enum.filter(chunks, &(&1.type == :meta))

      assert length(tool_chunks) == 1
      assert length(meta_chunks) == 1

      # Verify tool call content
      [tool_chunk] = tool_chunks
      assert tool_chunk.name == "get_weather"
      assert tool_chunk.args == %{"location" => "New York", "unit" => "celsius"}
      assert tool_chunk.meta[:id] == "call_123"

      # Verify meta chunk
      [meta_chunk] = meta_chunks
      assert meta_chunk.meta[:done] == true
      assert meta_chunk.meta[:finish_reason] == :stop
    end

    test "assembles multiple concurrent tool calls with different indices" do
      events = [
        # First tool call starts
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "id" => "call_001", "function" => %{"name" => "get_weather", "arguments" => "{\"location\":"}}
        ]}}]}},
        # Second tool call starts
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 1, "id" => "call_002", "function" => %{"name" => "get_news", "arguments" => "{\"topic\":"}}
        ]}}]}},
        # Continue first tool call
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => " \"Paris\"}"}}
        ]}}]}},
        # Continue second tool call
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 1, "function" => %{"arguments" => " \"tech\"}"}}
        ]}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))
      assert length(tool_chunks) == 2

      # Verify both tool calls were assembled correctly
      weather_chunk = Enum.find(tool_chunks, &(&1.name == "get_weather"))
      assert weather_chunk.args == %{"location" => "Paris"}
      assert weather_chunk.meta[:id] == "call_001"

      news_chunk = Enum.find(tool_chunks, &(&1.name == "get_news"))
      assert news_chunk.args == %{"topic" => "tech"}
      assert news_chunk.meta[:id] == "call_002"
    end

    test "handles incomplete JSON gracefully" do
      events = [
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "id" => "call_456", "function" => %{"name" => "search"}}
        ]}}]}},
        # Incomplete JSON - missing closing brace
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => "{\"query\": \"elixir\""}}
        ]}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      # Should NOT emit a tool_call chunk due to invalid JSON
      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))
      assert length(tool_chunks) == 0

      # Should still emit the done meta chunk
      meta_chunks = Enum.filter(chunks, &(&1.type == :meta))
      assert length(meta_chunks) == 1
    end

    test "emits tool call only once when JSON becomes valid" do
      events = [
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "id" => "call_789", "function" => %{"name" => "calculate"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => "{\"a\": 5"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "function" => %{"arguments" => ", \"b\": 10}"}}
        ]}}]}},
        # Additional chunks that shouldn't trigger re-emission
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0}
        ]}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      # Should emit exactly one tool_call chunk when JSON becomes valid
      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))
      assert length(tool_chunks) == 1

      [tool_chunk] = tool_chunks
      assert tool_chunk.name == "calculate"
      assert tool_chunk.args == %{"a" => 5, "b" => 10}
      assert tool_chunk.meta[:id] == "call_789"
    end

    test "handles mixed content and tool calls" do
      events = [
        %{data: %{"choices" => [%{"delta" => %{"content" => "Let me check the weather"}}]}},
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => [
          %{"index" => 0, "id" => "call_mix", "function" => %{"name" => "get_weather", "arguments" => "{\"location\": \"Tokyo\"}"}}
        ]}}]}},
        %{data: %{"choices" => [%{"delta" => %{"content" => " for you."}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      # Should have text chunks, tool call chunk, and meta chunk
      text_chunks = Enum.filter(chunks, &(&1.type == :text))
      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))
      meta_chunks = Enum.filter(chunks, &(&1.type == :meta))

      assert length(text_chunks) == 2
      assert length(tool_chunks) == 1
      assert length(meta_chunks) == 1

      # Verify content order and values
      assert Enum.at(text_chunks, 0).text == "Let me check the weather"
      assert Enum.at(text_chunks, 1).text == " for you."

      [tool_chunk] = tool_chunks
      assert tool_chunk.name == "get_weather"
      assert tool_chunk.args == %{"location" => "Tokyo"}
    end

    test "handles empty tool call arrays gracefully" do
      events = [
        %{data: %{"choices" => [%{"delta" => %{"tool_calls" => []}}]}},
        %{data: %{"choices" => [%{"delta" => %{"content" => "No tools needed"}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      # Should only have text and meta chunks, no tool calls
      text_chunks = Enum.filter(chunks, &(&1.type == :text))
      tool_chunks = Enum.filter(chunks, &(&1.type == :tool_call))

      assert length(text_chunks) == 1
      assert length(tool_chunks) == 0
      assert Enum.at(text_chunks, 0).text == "No tools needed"
    end
  end

  describe "[DONE] message handling" do
    test "emits meta chunk with done flag" do
      events = [
        %{data: %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}},
        %{data: "[DONE]"}
      ]

      model = %Model{provider: :openai, model: "gpt-4o-mini"}
      wrapped_response = %ReqLLM.Providers.OpenAI.Response{
        payload: Stream.unfold(events, fn
          [] -> nil
          [h | t] -> {h, t}
        end)
      }

      response = ReqLLM.Response.Codec.decode_response(wrapped_response, model)
      chunks = Enum.to_list(response.stream)

      meta_chunks = Enum.filter(chunks, &(&1.type == :meta))
      assert length(meta_chunks) == 1

      [meta] = meta_chunks
      assert meta.meta[:done] == true
      assert meta.meta[:finish_reason] == :stop
    end
  end
end