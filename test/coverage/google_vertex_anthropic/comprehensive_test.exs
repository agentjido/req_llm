defmodule ReqLLM.Coverage.GoogleVertex.ComprehensiveTest do
  @moduledoc """
  Comprehensive Google Vertex AI API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :google_vertex
end
