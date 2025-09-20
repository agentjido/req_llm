defmodule ReqLLM.Coverage.Anthropic.CoreTest do
  @moduledoc """
  Core Anthropic API feature coverage tests using simple fixtures.

  Run with LIVE=true to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :anthropic,
    model: "anthropic:claude-3-haiku-20240307"

  # Anthropic-specific tests
  test "sampling parameters" do
    {:ok, response} =
      ReqLLM.generate_text(
        "anthropic:claude-3-haiku-20240307",
        "Count to 3",
        temperature: 0.0,
        top_p: 0.9,
        max_tokens: 15,
        fixture: "sampling_params"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
  end

  test "stop sequences" do
    {:ok, response} =
      ReqLLM.generate_text(
        "anthropic:claude-3-haiku-20240307",
        "Count from 1 to 10, then say STOP",
        stop: ["STOP"],
        max_tokens: 50,
        fixture: "stop_sequences"
      )

    assert %ReqLLM.Response{} = response
    text = ReqLLM.Response.text(response)
    assert is_binary(text)
    assert String.length(text) > 0
    assert response.id != nil
    refute String.contains?(text, "STOP")
  end
end
