defmodule ReqLLM.Coverage.XAI.ObjectGenerationTest do
  @moduledoc """
  XAI object generation API feature coverage tests.

  Tests structured object generation capabilities including:
  - Basic object generation with schemas
  - Streaming object generation
  - JSON delta accumulation for streaming
  - Schema validation and adherence
  - Complex nested object handling

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.ObjectGeneration,
    provider: :xai,
    model: "xai:grok-3"
end
