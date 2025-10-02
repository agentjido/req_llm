defmodule ReqLLM.Coverage.Anthropic.CoreTest do
  @moduledoc """
  Core Anthropic API feature coverage tests using simple fixtures.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core, provider: :anthropic
end
