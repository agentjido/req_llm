defmodule ReqLLM.Coverage.OpenAI.WebSearchTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag timeout: 180_000

  @model_spec "openai:gpt-5-mini"

  # Chat Completions serves web search only on `*-search-preview` models, and
  # enables it through the `web_search_options` body field rather than a tool.
  # This is the surface that returns citations in the nested `url_citation`
  # shape, so it proves normalization against real payloads.
  @chat_model_spec "openai:gpt-4o-mini-search-preview"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:web_search_basic)
  @tag model: "gpt-5-mini"
  test "web search reports tool usage and cost" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:web_search_basic),
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

    assert [%{"type" => "url_citation", "url" => url} | _] =
             ReqLLM.Response.annotations(response)

    assert is_binary(url)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:web_search_streaming)
  @tag model: "gpt-5-mini"
  test "web search reports tool usage and cost with streaming" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:web_search_streaming),
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

    assert [%{"type" => "url_citation", "url" => url} | _] =
             ReqLLM.Response.annotations(response)

    assert is_binary(url)
  end

  @tag model: "gpt-4o-mini-search-preview"
  test "chat completions web search normalizes nested citations" do
    opts =
      fixture_opts("web_search_chat_completions", web_search_options: %{})

    {:ok, response} =
      ReqLLM.generate_text(
        @chat_model_spec,
        "Use web search to find one recent AI model announcement and cite the source.",
        opts
      )

    annotations = ReqLLM.Response.annotations(response)
    assert annotations != []

    for annotation <- annotations do
      assert %{"type" => "url_citation", "url" => url, "title" => title} = annotation
      refute Map.has_key?(annotation, "url_citation")
      assert is_binary(url)
      assert is_binary(title)
    end

    assert response.provider_meta["annotations"] == annotations
  end

  @tag model: "gpt-4o-mini-search-preview"
  test "chat completions web search accumulates citations while streaming" do
    opts =
      fixture_opts("web_search_chat_completions_streaming",
        stream: true,
        web_search_options: %{}
      )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        @chat_model_spec,
        "Use web search to find one recent AI model announcement and cite the source.",
        opts
      )

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

    annotations = ReqLLM.Response.annotations(response)
    assert annotations != []
    assert annotations == Enum.uniq(annotations)

    for annotation <- annotations do
      assert %{"type" => "url_citation", "url" => url} = annotation
      refute Map.has_key?(annotation, "url_citation")
      assert is_binary(url)
    end
  end
end
