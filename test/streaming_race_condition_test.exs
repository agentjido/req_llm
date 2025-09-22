defmodule StreamingRaceConditionTest do
  use ExUnit.Case
  import Mox

  alias ReqLLM.{Generation, Config}

  setup :verify_on_exit!

  describe "streaming race condition issue #42" do
    test "reproduces BadMapError when streaming is enabled" do
      # This test reproduces the race condition that causes BadMapError
      # when streaming is enabled with OpenAI provider
      
      config = %Config{
        provider: ReqLLM.Provider.OpenAI,
        model: "gpt-3.5-turbo",
        api_key: "test-key",
        api_url: "https://api.openai.com/v1"
      }

      # Create a generation with streaming enabled
      generation = %Generation{
        config: config,
        prompt: "Test prompt",
        stream: true,  # This triggers the race condition
        max_tokens: 10
      }

      # Mock the HTTP adapter to simulate streaming response
      expect(Req.Test.Mock, :run, fn request ->
        # Simulate SSE streaming response
        body = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}
        
        data: {"choices":[{"delta":{"content":" world"}}]}
        
        data: [DONE]
        """
        
        {request, %Req.Response{status: 200, body: body}}
      end)

      # This should crash with BadMapError in the buggy version
      # After the fix, it should work correctly
      assert_raise Req.RequestError, ~r/BadMapError/, fn ->
        Generation.stream_text(generation, [])
      end
    end
  end
end