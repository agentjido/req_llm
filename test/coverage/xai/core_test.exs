defmodule ReqLLM.Coverage.XAI.CoreTest do
  @moduledoc """
  Core X.AI API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :xai,
    model: "xai:grok-3"

  # X.AI-specific tests
  test "grok model inference" do
    {:ok, response} =
      ReqLLM.generate_text(
        "xai:grok-3",
        "What is 5+5?",
        temperature: 0.0,
        max_tokens: 10,
        fixture: "grok_inference"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
    assert text =~ "10"
  end

  @tag :coverage
  @tag :core
  @tag :xai
  test "creative generation" do
    {:ok, response} =
      ReqLLM.generate_text(
        "xai:grok-3",
        "Write a creative greeting",
        temperature: 0.8,
        max_tokens: 20,
        fixture: "creative_generation"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end
end
