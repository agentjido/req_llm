defmodule ReqLLM.Providers.AnthropicStreamingTest do
  @moduledoc """
  Comprehensive tests for Anthropic streaming functionality to improve coverage.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.Response

  describe "decode_streaming_response/3 with raw SSE" do
    test "handles raw SSE body from :into callback" do
      raw_sse = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_123"}}

      event: content_block_delta
      data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Test"}}

      event: message_stop
      data: {"type":"message_stop"}
      """

      req = %{
        options: %{
          stream: true,
          model: "claude-3-haiku",
          context: %ReqLLM.Context{messages: []}
        },
        private: %{}
      }

      resp = %{
        status: 200,
        body: raw_sse
      }

      {_req_out, resp_out} = Anthropic.decode_response({req, resp})

      assert resp_out.body.stream?

      chunks = Enum.to_list(resp_out.body.stream)
      refute Enum.empty?(chunks)

      text_chunks = Enum.filter(chunks, &(&1.type == :content))
      text = Enum.map(text_chunks, & &1.text) |> Enum.join("")
      assert text == "Test"
    end

    test "handles Stream struct from normal SSE step" do
      _model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku"}

      # Simulate parsed SSE events in a Stream
      events = [
        %{
          data: %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => "Stream"}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => " test"}
          }
        }
      ]

      stream = Stream.map(events, & &1)

      req = %{
        options: %{
          stream: true,
          model: "claude-3-haiku",
          context: %ReqLLM.Context{messages: []}
        },
        private: %{}
      }

      resp = %{
        status: 200,
        body: stream
      }

      {_req_out, resp_out} = Anthropic.decode_response({req, resp})

      assert resp_out.body.stream?

      chunks = Enum.to_list(resp_out.body.stream)
      assert length(chunks) == 2

      text = Enum.map(chunks, & &1.text) |> Enum.join("")
      assert text == "Stream test"
    end

    test "falls back to real-time stream from request private" do
      test_stream = Stream.map([1, 2, 3], & &1)

      req = %{
        options: %{
          stream: true,
          model: "claude-3-haiku",
          context: %ReqLLM.Context{messages: []}
        },
        private: %{real_time_stream: test_stream}
      }

      resp = %{
        status: 200,
        # Neither Stream nor binary
        body: nil
      }

      {_req_out, resp_out} = Anthropic.decode_response({req, resp})

      assert resp_out.body.stream?
      assert resp_out.body.stream == test_stream
    end
  end

  describe "Anthropic.Response SSE event decoding" do
    test "decodes content_block_delta with text" do
      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{
            "type" => "text_delta",
            "text" => "Hello from Anthropic"
          }
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert [%ReqLLM.StreamChunk{type: :content, text: "Hello from Anthropic"}] = chunks
    end

    test "decodes content_block_start with text" do
      event = %{
        data: %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "text",
            "text" => "Starting text"
          }
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert [%ReqLLM.StreamChunk{type: :content, text: "Starting text"}] = chunks
    end

    test "decodes content_block_start with tool_use" do
      event = %{
        data: %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "tool_123",
            "name" => "calculator"
          }
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert [
               %ReqLLM.StreamChunk{
                 type: :tool_call,
                 name: "calculator",
                 arguments: %{},
                 metadata: %{id: "tool_123", start: true, block_index: 1}
               }
             ] = chunks
    end

    test "decodes content_block_stop" do
      event = %{
        data: %{
          "type" => "content_block_stop",
          "index" => 2
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert [
               %ReqLLM.StreamChunk{
                 type: :meta,
                 metadata: %{type: :block_stop, block_index: 2}
               }
             ] = chunks
    end

    test "decodes input_json_delta for tool calls" do
      event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{
            "type" => "input_json_delta",
            "partial_json" => ~s({"number": 42)
          }
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert [
               %ReqLLM.StreamChunk{
                 type: :meta,
                 metadata: %{
                   type: :tool_input_delta,
                   partial_json: ~s({"number": 42),
                   block_index: 1
                 }
               }
             ] = chunks
    end

    test "returns empty for unrecognized event types" do
      event = %{
        data: %{
          "type" => "unknown_event_type",
          "foo" => "bar"
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}
      chunks = Response.decode_sse_event(event, model)

      assert chunks == []
    end
  end

  describe "Response.decode_response/2" do
    test "decodes non-streaming Anthropic response" do
      data = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-haiku",
        "content" => [
          %{"type" => "text", "text" => "Hello, I can help!"}
        ],
        "stop_reason" => "stop",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 5
        }
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku"}

      {:ok, response} = Response.decode_response(data, model)

      assert response.id == "msg_123"
      assert response.model == "claude-3-haiku"
      assert response.finish_reason == :stop

      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               total_tokens: 15
             }

      assert response.message.role == :assistant
      assert [%{type: :text, text: "Hello, I can help!"}] = response.message.content
    end

    test "decodes response with tool use" do
      data = %{
        "id" => "msg_456",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tool_789",
            "name" => "search",
            "input" => %{"query" => "weather"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}

      {:ok, response} = Response.decode_response(data, model)

      assert response.finish_reason == :tool_calls

      assert [
               %{
                 type: :tool_call,
                 tool_name: "search",
                 input: %{"query" => "weather"},
                 tool_call_id: "tool_789"
               }
             ] = response.message.content
    end

    test "handles missing or invalid data gracefully" do
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3"}

      {:error, :not_implemented} = Response.decode_response("not a map", model)
      {:error, :not_implemented} = Response.decode_response(nil, model)
    end
  end
end
