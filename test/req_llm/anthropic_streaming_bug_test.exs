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
    
    test "Anthropic streaming returns empty chunks in live request" do
      # Demonstrates issue with live streaming requests
      # Set ANTHROPIC_API_KEY env var to run this test
      
      api_key = System.get_env("ANTHROPIC_API_KEY")
      
      if api_key do
        {:ok, response} = 
          ReqLLM.stream_text(
            "anthropic:claude-3-haiku-20240307",
            "Say hello",
            max_tokens: 10
          )
        
        chunks = Enum.to_list(response.stream)
        
        # Streaming currently returns empty chunks
        refute Enum.empty?(chunks),
               "Expected chunks from streaming response"
      else
        IO.puts("Skipping live test - no ANTHROPIC_API_KEY set")
      end
    end
  end
end