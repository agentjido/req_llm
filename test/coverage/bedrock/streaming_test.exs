defmodule ReqLLM.Coverage.Bedrock.StreamingTest do
  @moduledoc """
  Streaming feature coverage tests for AWS Bedrock provider.
  """

  use ReqLLM.ProviderTest.Streaming,
    provider: :amazon_bedrock,
    model: "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0"

  # import ReqLLM.Test.LiveFixture  # TODO: Fix this import

  test "streams with Anthropic models on Bedrock" do
    {:ok, response} =
      ReqLLM.stream_text(
        "amazon_bedrock:us.anthropic.claude-opus-4-20250514-v1:0",
        "Count from 1 to 3",
        stream: true,
        max_tokens: 50,
        provider_options: [
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          region: "us-east-1"
        ],
        fixture: "bedrock_streaming_anthropic"
      )

    assert response.stream?
    chunks = Enum.to_list(response.stream)
    refute Enum.empty?(chunks)

    text_chunks = Enum.filter(chunks, &(&1.type == :content))
    refute Enum.empty?(text_chunks)
  end
end
