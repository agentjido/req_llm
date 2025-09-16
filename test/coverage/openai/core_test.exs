defmodule ReqLLM.Coverage.OpenAI.CoreTest do
  @moduledoc """
  Core OpenAI API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :openai,
    model: "openai:gpt-4o-mini"

  # OpenAI-specific tests
  test "frequency and presence penalties" do
    {:ok, response} =
      ReqLLM.generate_text(
        "openai:gpt-4o-mini",
        "Repeat the word 'test' multiple times",
        frequency_penalty: 0.5,
        presence_penalty: 0.3,
        max_tokens: 20,
        fixture: "penalty_params"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end

  test "seed parameter for reproducibility" do
    {:ok, response} =
      ReqLLM.generate_text(
        "openai:gpt-4o-mini",
        "Generate a random number",
        seed: 12345,
        temperature: 0.0,
        max_tokens: 10,
        fixture: "seed_reproducibility"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end
end
