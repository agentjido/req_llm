defmodule ReqLLM.Coverage.OpenAI.UsageTest do
  @moduledoc """
  OpenAI usage and cost calculation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Usage, provider: :openai
end
