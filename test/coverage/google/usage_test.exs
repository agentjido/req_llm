defmodule ReqLLM.Coverage.Google.UsageTest do
  @moduledoc """
  Google usage and cost calculation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Usage, provider: :google
end
