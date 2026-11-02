defmodule ReqLLM.Coverage.XAI.WatermarkTest do
  use ExUnit.Case, async: false

  import ReqLLM.Context
  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.Response

  @moduletag :coverage
  @moduletag provider: "xai"
  @moduletag model: "grok-4.3"
  @moduletag timeout: 180_000

  @model_spec "xai:grok-4.3"

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:basic)
  test "replays watermark metadata from a Chat Completions response" do
    opts = reasoning_overlay(@model_spec, param_bundles().deterministic, 2000)

    assert {:ok, response} =
             ReqLLM.generate_text(
               @model_spec,
               "Hello world!",
               fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:basic), opts)
             )

    assert_watermarked(response)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:streaming)
  test "replays watermark metadata from a streamed Chat Completions response" do
    context =
      Context.new([
        system("You are a helpful, creative assistant."),
        user("Say hello in one short, imaginative sentence.")
      ])

    opts = reasoning_overlay(@model_spec, :xai, param_bundles(:xai).creative, 2000)

    assert {:ok, stream_response} =
             ReqLLM.stream_text(
               @model_spec,
               context,
               fixture_opts(
                 :xai,
                 ReqLLM.Test.CompatibilityScenario.fixture!(:streaming),
                 opts
               )
             )

    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
    assert_watermarked(response)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:web_search_basic)
  test "replays watermark metadata from a Responses API response" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:web_search_basic),
        xai_tools: [%{type: "web_search"}]
      )

    assert {:ok, response} =
             ReqLLM.generate_text(
               @model_spec,
               "Use web search to find one recent AI model announcement and cite the source.",
               opts
             )

    assert_watermarked(response)
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:web_search_streaming)
  test "replays watermark metadata from a streamed Responses API response" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:web_search_streaming),
        stream: true,
        xai_tools: [%{type: "web_search"}]
      )

    assert {:ok, stream_response} =
             ReqLLM.stream_text(
               @model_spec,
               "Use web search to find one recent AI model announcement and cite the source.",
               opts
             )

    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
    assert_watermarked(response)
  end

  defp assert_watermarked(response) do
    assert response.provider_meta[:watermarked] == true
    assert Response.call_metadata(response).provider_metadata[:watermarked] == true
    refute Map.has_key?(response.provider_meta, :headers)
    refute Map.has_key?(response.provider_meta, "headers")
  end
end
