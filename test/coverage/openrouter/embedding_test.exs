defmodule ReqLLM.Coverage.OpenRouter.EmbeddingTest do
  @moduledoc """
  OpenRouter embedding API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Embedding, provider: :openrouter
end
