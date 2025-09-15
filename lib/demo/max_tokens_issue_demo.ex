defmodule Demo.MaxTokensIssueDemo do
  @moduledoc """
  Demo script to demonstrate the max_tokens parameter translation issue
  without requiring Mix.install or real API calls.
  """

  alias ReqLLM.{Model, Context, Generation}

  def run do
    IO.puts("Max Tokens Parameter Translation Issue Demo")
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
      # Anthropic reasoning parameter
      thinking: true,
      # OpenAI reasoning parameter
      reasoning: "auto"
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

            # Show model capabilities that should influence translation
            show_model_capabilities(model)

          {:error, error} ->
            IO.puts("  Validation Error: #{inspect(error)}")
        end
      else
        error -> IO.puts("  Error: #{inspect(error)}")
      end
    end)
  end

  defp show_model_capabilities(model) do
    capabilities = model.capabilities || %{}
    IO.puts("  Model Capabilities:")
    IO.puts("    Temperature: #{Map.get(capabilities, :temperature, "unknown")}")
    IO.puts("    Reasoning: #{Map.get(capabilities, :reasoning, "unknown")}")
    IO.puts("    Tool Call: #{Map.get(capabilities, :tool_call, "unknown")}")
    IO.puts("    Attachment: #{Map.get(capabilities, :attachment, "unknown")}")
  end

  defp show_required_translations do
    IO.puts("\n--- Required Parameter Translations ---")

    translations = [
      %{
        model: "openai:o1",
        issue: "Uses max_completion_tokens instead of max_tokens",
        translation: %{max_tokens: :max_completion_tokens},
        unsupported: [:temperature],
        reason: "O1 models are reasoning models that don't support temperature"
      },
      %{
        model: "openai:gpt-4o",
        issue: "Standard max_tokens works fine",
        translation: %{},
        unsupported: [],
        reason: "Standard OpenAI model with full parameter support"
      },
      %{
        model: "anthropic:claude-3-sonnet",
        issue: "Uses 'thinking' parameter instead of 'reasoning'",
        translation: %{reasoning: :thinking},
        unsupported: [],
        reason: "Anthropic uses different parameter names for reasoning"
      }
    ]

    Enum.each(translations, fn t ->
      IO.puts("\n#{t.model}:")
      IO.puts("  Issue: #{t.issue}")
      IO.puts("  Parameter Translation: #{inspect(t.translation)}")
      IO.puts("  Unsupported Options: #{inspect(t.unsupported)}")
      IO.puts("  Reason: #{t.reason}")
    end)
  end

  defp build_test_context(message) do
    Context.new([Context.user(message)])
  end

  def demo_translation_dsl do
    IO.puts("\n--- Proposed Translation DSL ---")

    openai_example = """
    defmodule ReqLLM.Providers.OpenAI do
      use ReqLLM.Provider.ParameterTranslator
      
      translate do
        # Default mapping for all models
        map max_tokens: :max_tokens,
            temperature: :temperature,
            reasoning: :reasoning
        
        # O1 family specific overrides
        for_models ~r/^o1(-.*)?$/ do
          map max_tokens: :max_completion_tokens,
              temperature: :drop,  # Not supported
              reasoning: :reasoning
        end
      end
    end
    """

    anthropic_example = """
    defmodule ReqLLM.Providers.Anthropic do
      use ReqLLM.Provider.ParameterTranslator
      
      translate do
        # Global mapping
        map reasoning: :thinking,
            max_tokens: :max_tokens,
            temperature: :temperature
      end
    end
    """

    IO.puts("OpenAI Provider Translation Rules:")
    IO.puts(openai_example)

    IO.puts("Anthropic Provider Translation Rules:")
    IO.puts(anthropic_example)
  end
end
