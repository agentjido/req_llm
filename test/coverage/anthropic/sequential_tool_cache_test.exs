defmodule ReqLLM.Coverage.Anthropic.SequentialToolCacheTest do
  use ExUnit.Case, async: false

  alias ReqLLM.ProviderTest.SequentialToolCache
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "anthropic"
  @moduletag model: "claude-haiku-4-5-20251001"
  @moduletag timeout: 180_000

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag CompatibilityScenario.tag!(:sequential_tool_cache)
  test "three sequential tool rounds preserve the Anthropic prompt cache" do
    SequentialToolCache.run("anthropic:claude-haiku-4-5-20251001",
      assert_initial_cache: true,
      provider_options: [
        anthropic_prompt_cache: true,
        anthropic_cache_messages: true
      ]
    )
  end
end
