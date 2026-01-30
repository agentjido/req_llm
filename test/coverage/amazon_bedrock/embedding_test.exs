defmodule ReqLLM.Coverage.AmazonBedrock.EmbeddingTest do
  @moduledoc """
  Amazon Bedrock embedding API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.

  Note: Bedrock requires AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION)
  or a bearer token (AWS_BEARER_TOKEN_BEDROCK) when recording fixtures.
  """

  use ReqLLM.ProviderTest.Embedding, provider: :amazon_bedrock
end
