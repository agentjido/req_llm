defmodule ReqLLM.Coverage.XAI.ToolCallingTest do
  @moduledoc """
  xAI tool calling API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.ToolCalling, provider: :xai
end
