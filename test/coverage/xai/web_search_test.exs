defmodule ReqLLM.Coverage.XAI.WebSearchTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "xai"
  @moduletag timeout: 180_000

  @model_spec "xai:grok-4-fast-reasoning"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag scenario: :web_search_basic
  @tag model: "grok-4-fast-reasoning"
  test "web search reports tool usage and cost" do
    opts =
      fixture_opts("web_search_basic",
        xai_tools: [%{type: "web_search"}]
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

  @tag scenario: :web_search_streaming
  @tag model: "grok-4-fast-reasoning"
  test "web search reports tool usage and cost with streaming" do
    opts =
      fixture_opts("web_search_streaming",
        stream: true,
        xai_tools: [%{type: "web_search"}]
      )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        @model_spec,
        "Use web search to find one recent AI model announcement and cite the source.",
        opts
      )

    assert stream_response.stream != nil

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

    assert response.usage.tool_usage.web_search.count > 0
    assert response.usage.cost.tools > 0
  end

  @tag scenario: :x_search_streaming
  @tag model: "grok-4-fast-reasoning"
  test "x search reports tool usage and cost with streaming" do
    opts =
      fixture_opts("x_search_streaming",
        stream: true,
        xai_tools: [%{type: "x_search"}]
      )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        @model_spec,
        "Use x search to find one recent AI model announcement and cite the source.",
        opts
      )

    assert stream_response.stream != nil

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

    assert response.usage.tool_usage.x_search.count > 0
    assert response.usage.cost.tools > 0
  end
end
