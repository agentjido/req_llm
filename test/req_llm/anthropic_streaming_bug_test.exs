defmodule ReqLLM.AnthropicStreamingBugTest do
  @moduledoc """
  Test demonstrating Anthropic streaming issue in main branch.

  These tests show that Anthropic streaming fails due to:
  1. Map protocol not supporting Anthropic's content_block_delta format
  2. Streaming decode making recursive HTTP requests causing timeouts
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  describe "Anthropic streaming issue demonstration" do
    test "Map protocol doesn't decode Anthropic streaming events" do
      # This test shows that the Map protocol implementation
      # in ReqLLM.Response.Codec doesn't handle Anthropic's streaming format

      # Sample Anthropic SSE event structure
      anthropic_event = %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{
            "type" => "text_delta",
            "text" => "Hello, world!"
          }
        },
        event: "content_block_delta"
      }

      # This should return chunks but returns empty list on broken main
      model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku"}
      chunks = ReqLLM.Response.Codec.decode_sse_event(anthropic_event, model)

      # Currently returns empty list instead of chunks
      assert chunks == [%ReqLLM.StreamChunk{type: :content, text: "Hello, world!"}],
             "Expected Anthropic event to decode to chunks, got: #{inspect(chunks)}"
    end

    test "Anthropic streaming processes SSE response correctly" do
      # Test that mimics what happens with real streaming
      # The issue was that when :into callback is used, the body comes back as raw SSE

      _model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-haiku-20240307"}

      # Raw SSE response as it comes from Anthropic
      raw_sse_body = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","model":"claude-3-haiku-20240307","content":[]}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello!"}}

      event: message_stop
      data: {"type":"message_stop"}
      """

      # Simulate the request/response as it happens in real streaming
      req = %{
        options: %{
          stream: true,
          model: "claude-3-haiku-20240307",
          context: %ReqLLM.Context{messages: []}
        },
        private: %{}
      }

      resp = %{
        status: 200,
        # This is what we get with :into callback
        body: raw_sse_body
      }

      # Call the provider's decode_response directly
      {_req_out, resp_out} = apply(ReqLLM.Providers.Anthropic, :decode_response, [{req, resp}])

      # Should have created a streaming response
      assert resp_out.body.stream?

      # Collect chunks from the stream
      chunks = Enum.to_list(resp_out.body.stream)

      # This would be empty without the fix
      refute Enum.empty?(chunks),
             "Expected chunks from streaming response, got empty list"

      # Verify we get the text content
      text_chunks = Enum.filter(chunks, &(&1.type == :content))
      text = Enum.map(text_chunks, & &1.text) |> Enum.join("")
      assert text == "Hello!"
    end
  end
end
