defmodule ReqLLM.Coverage.Anthropic.UsageTest do
  @moduledoc """
  Anthropic usage and cost calculation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Usage, provider: :anthropic
end
