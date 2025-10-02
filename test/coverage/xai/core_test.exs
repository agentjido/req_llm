defmodule ReqLLM.Coverage.XAI.CoreTest do
  @moduledoc """
  Core xAI API feature coverage tests using simple fixtures.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core, provider: :xai
end
