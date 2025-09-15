#!/usr/bin/env elixir

# Mock test script to demonstrate the max_tokens parameter translation issue
# This shows what the current generation module produces vs what's needed

Mix.install([
  {:req_llm, path: "."},
  {:jason, "~> 1.4"}
])

defmodule MockMaxTokensTest do
  @moduledoc """
  Mock test to demonstrate the parameter translation issue without requiring API calls.
  """
  
  alias ReqLLM.{Model, Context, Generation}
  
  def run do
    IO.puts("Mock Test: Parameter Translation Issue")
    IO.puts("=" <> String.duplicate("=", 50))
    
    # Test current parameter handling
    test_current_approach()
    
    # Show what we need for different models
    show_required_translations()
  end
  
  defp test_current_approach do
    IO.puts("\n--- Current Parameter Handling ---")
    
    # Parse different models
    models = [
      "openai:o1",
      "openai:gpt-4o", 
      "openai:gpt-3.5-turbo",
      "anthropic:claude-3-sonnet"
    ]
    
    opts = [
      max_tokens: 1000,
      temperature: 0.7,
      thinking: true,  # Anthropic reasoning parameter
      reasoning: "auto" # OpenAI reasoning parameter
    ]
    
    Enum.each(models, fn model_spec ->
      with {:ok, model} <- Model.from(model_spec),
           {:ok, provider_module} <- ReqLLM.provider(model.provider) do
        
        IO.puts("\nModel: #{model_spec}")
        IO.puts("  Provider: #{model.provider}")
        IO.puts("  Model ID: #{model.model}")
        
        # Show what the current generation schema produces
        schema = Generation.dynamic_schema(provider_module)
        case NimbleOptions.validate(opts, schema) do
          {:ok, validated_opts} ->
            IO.puts("  Validated Options: #{inspect(validated_opts, limit: :infinity)}")
            
            # This is where the problem occurs - we need to translate options
            # before they go to the provider's prepare_request
            context = build_test_context("Hello")
            
            IO.puts("  Context: #{inspect(Context.to_list(context), limit: :infinity)}")
            
          {:error, error} ->
            IO.puts("  Validation Error: #{inspect(error)}")
        end
      else
        error -> IO.puts("  Error: #{inspect(error)}")
      end
    end)
  end
  
  defp show_required_translations do
    IO.puts("\n--- Required Parameter Translations ---")
    
    translations = [
      %{
        model: "openai:o1",
        issue: "Uses max_completion_tokens instead of max_tokens",
        translation: %{max_tokens: :max_completion_tokens},
        unsupported: [:temperature]
      },
      %{
        model: "openai:gpt-4o", 
        issue: "Standard max_tokens works fine",
        translation: %{},
        unsupported: []
      },
      %{
        model: "anthropic:claude-3-sonnet",
        issue: "Uses 'thinking' parameter instead of 'reasoning'",  
        translation: %{reasoning: :thinking},
        unsupported: []
      }
    ]
    
    Enum.each(translations, fn t ->
      IO.puts("\n#{t.model}:")
      IO.puts("  Issue: #{t.issue}")
      IO.puts("  Parameter Translation: #{inspect(t.translation)}")
      IO.puts("  Unsupported Options: #{inspect(t.unsupported)}")
    end)
  end
  
  defp build_test_context(message) do
    Context.new([Context.user(message)])
  end
end

MockMaxTokensTest.run()
