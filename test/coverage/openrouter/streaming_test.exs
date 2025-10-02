defmodule ReqLLM.Coverage.OpenRouter.StreamingTest do
  @moduledoc """
  OpenRouter streaming API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.

  Limited to a small set of representative models due to OpenRouter's large catalog.
  """

  use ReqLLM.ProviderTest.Streaming,
    provider: :openrouter,
    models: [
      "openrouter/horizon-alpha",
      "openai/gpt-4o-mini"
    ]
end
