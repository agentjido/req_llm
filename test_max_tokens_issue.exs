#!/usr/bin/env elixir

# Standalone test script to reproduce the max_tokens vs max_completion_tokens issue
# with OpenAI o1 models reported in GitHub issue #8

Mix.install([
  {:req_llm, path: "."},
  {:jason, "~> 1.4"}
])

defmodule TestMaxTokensIssue do
  @moduledoc """
  Test script to reproduce the max_tokens issue with OpenAI o1 models.
  
  Expected behavior: Should fail with "max_tokens is not supported" error
  when using o1 models, but work fine with other OpenAI models.
  """

  def run do
    IO.puts("Testing max_tokens parameter with different OpenAI models...")
    IO.puts("=" <> String.duplicate("=", 60))
    
    # Test with o1 model - should fail
    test_model("openai:o1", "o1 model (should fail with max_tokens error)")
    
    # Test with gpt-4o model - should work  
    test_model("openai:gpt-4o", "gpt-4o model (should work)")
    
    # Test with gpt-3.5-turbo - should work
    test_model("openai:gpt-3.5-turbo", "gpt-3.5-turbo model (should work)")
  end
  
  defp test_model(model_spec, description) do
    IO.puts("\n--- Testing #{description} ---")
    
    opts = [
      max_tokens: 100,
      temperature: 0.7
    ]
    
    case ReqLLM.Generation.generate_text!(model_spec, "Hello, respond with a short greeting", opts) do
      {:ok, text} ->
        IO.puts("✅ SUCCESS: #{String.slice(text, 0, 50)}...")
        
      {:error, %ReqLLM.Error.API.Request{} = error} ->
        IO.puts("❌ API ERROR: #{error.message}")
        if error.response do
          IO.puts("   Status: #{error.response.status}")
          IO.puts("   Body: #{inspect(error.response.body)}")
        end
        
      {:error, error} ->
        IO.puts("❌ OTHER ERROR: #{inspect(error)}")
    end
  end
end

# Check if OPENAI_API_KEY is set
case System.get_env("OPENAI_API_KEY") do
  nil ->
    IO.puts("❌ Error: OPENAI_API_KEY environment variable not set")
    IO.puts("Please set your OpenAI API key: export OPENAI_API_KEY=your_key_here")
    :erlang.halt(1)
    
  _key ->
    IO.puts("✅ OPENAI_API_KEY found")
    TestMaxTokensIssue.run()
end
