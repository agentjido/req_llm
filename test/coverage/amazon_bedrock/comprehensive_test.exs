defmodule ReqLLM.Coverage.AmazonBedrock.ComprehensiveTest do
  @moduledoc """
  Comprehensive AWS Bedrock API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Comprehensive, provider: :amazon_bedrock
end
