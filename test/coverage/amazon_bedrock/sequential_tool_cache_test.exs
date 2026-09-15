defmodule ReqLLM.Coverage.AmazonBedrock.SequentialToolCacheTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record and AWS_REGION=us-east-1.
  """
  use ExUnit.Case, async: false

  alias ReqLLM.ProviderTest.SequentialToolCache
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag CompatibilityScenario.tag!(:sequential_tool_cache)
  test "three sequential tool rounds preserve the Bedrock Converse prompt cache" do
    SequentialToolCache.run(@model,
      assert_initial_cache: true,
      provider_options: [prompt_cache: true, cache_messages: true]
    )
  end
end
