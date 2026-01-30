defmodule ReqLLM.Coverage.OpenAI.WebSearchTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag timeout: 180_000

  @model_spec "openai:gpt-5-mini"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag scenario: :web_search_basic
  @tag model: "gpt-5-mini"
  test "web search reports tool usage and cost" do
    opts =
      fixture_opts("web_search_basic",
        tools: [%{"type" => "web_search"}]
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
  @tag model: "gpt-5-mini"
  test "web search reports tool usage and cost with streaming" do
    opts =
      fixture_opts("web_search_streaming",
        stream: true,
        tools: [%{"type" => "web_search"}]
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
end
