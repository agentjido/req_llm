defmodule ReqLLM.Coverage.ZaiCodingPlan.SequentialToolCacheTest do
  use ExUnit.Case, async: false

  alias ReqLLM.ProviderTest.SequentialToolCache
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "zai_coding_plan"
  @moduletag model: "glm-5.3-flash"
  @moduletag timeout: 180_000

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag CompatibilityScenario.tag!(:sequential_tool_cache)
  test "three sequential tool rounds preserve the Z.ai prompt cache" do
    SequentialToolCache.run("zai_coding_plan:glm-5.3-flash",
      provider_options: [thinking: %{type: "disabled"}]
    )
  end
end
