defmodule ReqLLM.Coverage.OpenRouter.CoreTest do
  @moduledoc """
  Core OpenRouter API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :openrouter,
    model: "openrouter:openai/gpt-4o-mini"

  # OpenRouter-specific tests
  test "free model access" do
    {:ok, response} =
      ReqLLM.generate_text(
        "openrouter:openai/gpt-4o-mini",
        "Hello world",
        temperature: 0.0,
        max_tokens: 10,
        fixture: "free_model_access"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end

  test "model routing" do
    {:ok, response} =
      ReqLLM.generate_text(
        "openrouter:openai/gpt-4o-mini",
        "Count to 3",
        temperature: 0.5,
        max_tokens: 15,
        fixture: "model_routing"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end
end
