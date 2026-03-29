defmodule ReqLLM.Providers.Anthropic.ResponseTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic.Response

  setup do
    {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
    {:ok, model: model}
  end

  describe "decode_stream_event/2 - ping events" do
    test "ping event emits a keepalive meta chunk instead of being swallowed", %{model: model} do
      event = %{data: %{"type" => "ping"}}

      # Ping events must produce a chunk so downstream consumers (e.g. stall
      # timeout monitors) see activity on the stream. Returning [] causes
      # false stall timeouts during long-thinking requests (issue #731).
      chunks = Response.decode_stream_event(event, model)

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: %{ping: true}}] = chunks
    end

    test "ping keepalive chunk carries no text or tool call data", %{model: model} do
      event = %{data: %{"type" => "ping"}}

      [chunk] = Response.decode_stream_event(event, model)

      assert chunk.text == nil
      assert chunk.name == nil
      assert chunk.arguments == nil
    end
  end

  describe "decode_stream_event/2 - content events" do
    test "content_block_delta with text_delta produces content chunk", %{model: model} do
      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hello"}
        }
      }

      assert [chunk] = Response.decode_stream_event(event, model)
      assert chunk.type == :content
      assert chunk.text == "Hello"
    end

    test "message_start with usage emits meta chunk", %{model: model} do
      event = %{
        data: %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
          }
        }
      }

      assert [chunk] = Response.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.usage.input_tokens == 10
    end

    test "message_stop emits terminal meta chunk", %{model: model} do
      event = %{data: %{"type" => "message_stop"}}

      assert [chunk] = Response.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata[:terminal?] == true
    end

    test "content_block_stop returns empty list", %{model: model} do
      event = %{data: %{"type" => "content_block_stop"}}

      assert [] = Response.decode_stream_event(event, model)
    end

    test "unknown event type returns empty list", %{model: model} do
      event = %{data: %{"type" => "unknown_future_event"}}

      assert [] = Response.decode_stream_event(event, model)
    end
  end

  describe "decode_stream_event/2 - thinking events" do
    test "thinking_delta produces thinking chunk", %{model: model} do
      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Let me consider..."}
        }
      }

      assert [chunk] = Response.decode_stream_event(event, model)
      assert chunk.type == :thinking
      assert chunk.text == "Let me consider..."
    end
  end

  describe "decode_stream_event/2 - message_delta (finish reasons)" do
    test "end_turn stop reason maps to :stop", %{model: model} do
      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{}
        }
      }

      chunks = Response.decode_stream_event(event, model)
      finish_chunk = Enum.find(chunks, &(&1.metadata[:finish_reason] != nil))

      assert finish_chunk.metadata.finish_reason == :stop
    end

    test "tool_use stop reason maps to :tool_calls", %{model: model} do
      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{}
        }
      }

      chunks = Response.decode_stream_event(event, model)
      finish_chunk = Enum.find(chunks, &(&1.metadata[:finish_reason] != nil))

      assert finish_chunk.metadata.finish_reason == :tool_calls
    end
  end
end
