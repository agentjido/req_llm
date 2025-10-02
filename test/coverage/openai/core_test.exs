defmodule ReqLLM.Coverage.OpenAI.CoreTest do
  @moduledoc """
  Core OpenAI API feature coverage tests using simple fixtures.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core, provider: :openai
end
