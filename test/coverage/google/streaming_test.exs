defmodule ReqLLM.Coverage.Google.StreamingTest do
  @moduledoc """
  Google Gemini streaming API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Streaming,
    provider: :google,
    model: "google:gemini-2.5-flash"
end
