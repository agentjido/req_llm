defmodule ReqLLM.Coverage.Bedrock.CoreTest do
  @moduledoc """
  Core AWS Bedrock API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Core,
    provider: :amazon_bedrock,
    model: "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0"

  # import ReqLLM.Test.LiveFixture  # TODO: Fix this import

  test "temperature and sampling parameters" do
    {:ok, response} =
      ReqLLM.generate_text(
        "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0",
        "Count to 3",
        temperature: 0.0,
        top_p: 0.9,
        max_tokens: 10,
        provider_options: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        fixture: "bedrock_sampling_params"
      )

    refute is_nil(response.message)
  end

  test "supports Anthropic-specific parameters" do
    {:ok, response} =
      ReqLLM.generate_text(
        "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0",
        "Say hello",
        max_tokens: 100,
        top_k: 40,
        stop: ["\\n\\n"],
        provider_options: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        fixture: "bedrock_anthropic_params"
      )

    assert response.model =~ "claude"
  end

  test "handles region-prefixed model IDs" do
    {:ok, response} =
      ReqLLM.generate_text(
        "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0",
        "Reply with one word",
        max_tokens: 10,
        provider_options: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        fixture: "bedrock_region_prefixed"
      )

    assert response.usage.total_tokens > 0
  end
end
