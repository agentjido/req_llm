defmodule ReqLLM.Coverage.Google.ToolCallingTest do
  @moduledoc """
  Google tool calling API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.ToolCalling,
    provider: :google,
    model: "google:gemini-2.5-flash"
end
