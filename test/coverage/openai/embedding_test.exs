defmodule ReqLLM.Coverage.OpenAI.EmbeddingTest do
  @moduledoc """
  OpenAI embedding API feature coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Embedding, provider: :openai

  @tag category: :embedding
  @tag scenario: :embed_basic
  @tag model: "text-embedding-3-small"
  test "return_usage includes cost fields" do
    {:ok, %{usage: usage}} =
      ReqLLM.embed(
        "openai:text-embedding-3-small",
        "Hello world",
        fixture_opts("embed_basic", return_usage: true)
      )

    assert usage.input_tokens > 0
    assert is_number(usage.input_cost)
    assert is_number(usage.total_cost)
  end
end
