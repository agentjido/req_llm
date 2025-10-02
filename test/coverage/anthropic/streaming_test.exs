defmodule ReqLLM.Coverage.Anthropic.StreamingTest do
  @moduledoc """
  Anthropic streaming API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Streaming, provider: :anthropic
end
