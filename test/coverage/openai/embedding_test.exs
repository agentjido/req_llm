defmodule ReqLLM.Coverage.OpenAI.EmbeddingTest do
  @moduledoc """
  OpenAI embedding API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Embedding,
    provider: :openai,
    model: "openai:text-embedding-3-small"

  # OpenAI-specific embedding tests can be added here
  # For example: dimension reduction, encoding format specifics, etc.
end