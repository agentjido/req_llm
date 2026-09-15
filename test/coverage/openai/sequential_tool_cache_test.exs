defmodule ReqLLM.Coverage.OpenAI.SequentialToolCacheTest do
  use ExUnit.Case, async: false

  alias ReqLLM.ProviderTest.SequentialToolCache
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag model: "gpt-4.1-mini"
  @moduletag timeout: 180_000

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag CompatibilityScenario.tag!(:sequential_tool_cache)
  test "three sequential tool rounds preserve the OpenAI prompt cache" do
    SequentialToolCache.run("openai:gpt-4.1-mini",
      provider_options: [prompt_cache_key: "reqllm-sequential-tool-cache-v1"]
    )
  end
end
