defmodule ReqLLM.Coverage.OpenRouter.UsageTest do
  @moduledoc """
  OpenRouter usage and cost calculation coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.

  Limited to a small set of representative models due to OpenRouter's large catalog.
  """

  use ReqLLM.ProviderTest.Usage,
    provider: :openrouter,
    models: [
      "openrouter/horizon-alpha",
      "openai/gpt-4o-mini"
    ]
end
