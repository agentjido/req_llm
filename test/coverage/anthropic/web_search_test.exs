defmodule ReqLLM.Coverage.Anthropic.WebSearchTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "anthropic"
  @moduletag timeout: 180_000

  @model_spec "anthropic:claude-sonnet-4-5"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:web_search_basic)
  @tag model: "claude-sonnet-4-5"
  test "web search reports tool usage and cost" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:web_search_basic),
        provider_options: [
          web_search: %{max_uses: 2}
        ]
      )

    {:ok, response} =
      ReqLLM.generate_text(
        @model_spec,
        "Use web search to find one recent AI model announcement and cite the source.",
        opts
      )

    assert response.usage.tool_usage.web_search.count > 0
    assert response.usage.cost.tools > 0
  end
end
