defmodule Demo.ComprehensiveDemo do
  @moduledoc """
  Comprehensive demo showing the max_tokens parameter translation issue
  and demonstrating the proposed solution.
  """

  def run_all do
    IO.puts("🚀 ReqLLM Parameter Translation Issue - Comprehensive Demo")
    IO.puts("=" <> String.duplicate("=", 65))

    # Part 1: Show the current issue
    show_current_issue()

    # Part 2: Demonstrate with real API calls
    demonstrate_real_api_issue()

    # Part 3: Show the proposed solution
    show_proposed_solution()
  end

  defp show_current_issue do
    IO.puts("\n📋 PART 1: Current Issue Analysis")
    IO.puts("-" <> String.duplicate("-", 40))

    Demo.MaxTokensIssueDemo.run()
  end

  defp demonstrate_real_api_issue do
    IO.puts("\n🌐 PART 2: Real API Demonstration")
    IO.puts("-" <> String.duplicate("-", 40))

    case ReqLLM.get_key(:openai_api_key) do
      nil ->
        IO.puts("⚠️  Skipping real API tests - no OpenAI API key available")

      _key ->
        Demo.RealApiTest.run()
        IO.puts("")
        Demo.RealApiTest.test_with_provider_options()
    end
  end

  defp show_proposed_solution do
    IO.puts("\n💡 PART 3: Proposed Solution")
    IO.puts("-" <> String.duplicate("-", 40))

    Demo.MaxTokensIssueDemo.demo_translation_dsl()

    IO.puts("\n🎯 Key Benefits:")
    IO.puts("  ✅ Backward compatible - all existing code works unchanged")
    IO.puts("  ✅ Declarative - easy to add new model-specific rules")
    IO.puts("  ✅ Extensible - handles parameter renames and removals")
    IO.puts("  ✅ Provider agnostic - works with any AI provider")
    IO.puts("  ✅ Performance optimized - compile-time DSL expansion")

    IO.puts("\n📋 Implementation Plan:")
    IO.puts("  1. Create ParameterTranslator behavior and DSL")
    IO.puts("  2. Add translation step to Generation module")
    IO.puts("  3. Update OpenAI provider with o1 model rules")
    IO.puts("  4. Add Anthropic reasoning -> thinking translation")
    IO.puts("  5. Test thoroughly with real APIs")

    IO.puts("\n🚀 After implementation, this will work:")
    IO.puts(~s{     ReqLLM.generate_text!("openai:o1", "Hello", max_tokens: 100)})
    IO.puts("     # Automatically translates to max_completion_tokens")

    IO.puts("\n📖 See OPTIONS_PLAN.md for complete implementation details")
  end
end
