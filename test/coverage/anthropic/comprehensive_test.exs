defmodule ReqLLM.Coverage.Anthropic.ComprehensiveTest do
  @moduledoc """
  Comprehensive Anthropic provider tests.

  Tests all models from ModelMatrix with consolidated test suite:
  - Basic generate_text (non-streaming)
  - Streaming with system context + creative params
  - Token limit constraints
  - Usage metrics and cost calculations
  - Tool calling capabilities
  - Object generation (streaming)

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :anthropic
end
