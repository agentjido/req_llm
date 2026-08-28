defmodule ReqLLM.Coverage.AmazonBedrock.MantleTest do
  @moduledoc """
  bedrock-mantle coverage tests.

  Run with REQ_LLM_FIXTURES_MODE=record to test against the live API and record
  fixtures. Otherwise uses fixtures for fast, reliable testing.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @routes [
    chat_completions: "amazon_bedrock:openai.gpt-oss-120b",
    openai_v1_chat_completions: "amazon_bedrock:google.gemma-4-31b",
    messages: "amazon_bedrock:anthropic.claude-sonnet-5"
  ]

  @opts [provider_options: [endpoint: :mantle], max_tokens: 400]

  for {route, model} <- @routes do
    @model model

    test "#{route}: generate_text through bedrock-mantle" do
      opts = fixture_opts("mantle_basic", @opts)

      {:ok, response} = ReqLLM.generate_text(@model, "Say hi in two words.", opts)

      assert ReqLLM.Response.text(response) =~ ~r/\S/
      assert response.usage.output_tokens > 0
    end

    test "#{route}: stream_text through bedrock-mantle" do
      opts = fixture_opts("mantle_streaming", @opts)

      {:ok, response} = ReqLLM.stream_text(@model, "Say hi in two words.", opts)

      assert ReqLLM.StreamResponse.text(response) =~ ~r/\S/
    end
  end
end
