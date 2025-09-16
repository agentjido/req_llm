defmodule ReqLLM.Coverage.Groq.CoreTest do
  @moduledoc """
  Core Groq API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :groq,
    model: "groq:llama-3.1-8b-instant"

  # Groq-specific tests
  test "high speed inference" do
    {:ok, response} =
      ReqLLM.generate_text(
        "groq:llama-3.1-8b-instant",
        "What is 2+2?",
        temperature: 0.0,
        max_tokens: 10,
        fixture: "high_speed_inference"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
    assert text =~ "4"
  end

  test "top_p parameter" do
    {:ok, response} =
      ReqLLM.generate_text(
        "groq:llama-3.1-8b-instant",
        "Tell me a brief fact",
        temperature: 0.7,
        top_p: 0.9,
        max_tokens: 20,
        fixture: "top_p_param"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end
end
