defmodule ReqLLM.Coverage.GoogleVertexGemini.EmbeddingTest do
  @moduledoc """
  Google Vertex AI Gemini embedding API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Embedding, provider: :google_vertex
end
