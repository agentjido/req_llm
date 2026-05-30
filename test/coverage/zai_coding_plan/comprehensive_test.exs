defmodule ReqLLM.Coverage.ZaiCodingPlan.ComprehensiveTest do
  @moduledoc """
  Comprehensive Z.ai coding-plan API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :zai_coding_plan
end
