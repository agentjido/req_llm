defmodule ReqLLM.Coverage.OpenAI.ToolCallingTest do
  @moduledoc """
  OpenAI tool calling API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.ToolCalling, provider: :openai
end
