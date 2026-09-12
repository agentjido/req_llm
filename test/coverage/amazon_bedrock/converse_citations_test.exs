defmodule ReqLLM.Coverage.AmazonBedrock.ConverseCitationsTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record and AWS_REGION=us-east-1.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"
  @opts [max_tokens: 256, provider_options: [use_converse: true]]

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  defp context do
    pdf = File.read!("priv/examples/test.pdf")

    Context.new([
      Context.user([
        ContentPart.text("What's in this document? Quote its text."),
        ContentPart.file(pdf, "MyDocument.pdf", "application/pdf", %{citations: true})
      ])
    ])
  end

  defp assert_cited(response) do
    assert ReqLLM.Response.text(response) =~ "Test PDF Document"

    assert [
             %{
               "title" => "MyDocument",
               "sourceContent" => [%{"text" => source}],
               "location" => location
             }
             | _
           ] =
             ReqLLM.Response.annotations(response)

    assert source =~ "Test PDF Document"
    assert %{"documentPage" => %{"documentIndex" => 0}} = location
  end

  test "cites the document it quotes" do
    {:ok, response} =
      ReqLLM.generate_text(@model, context(), fixture_opts("converse_citations", @opts))

    assert_cited(response)
  end

  test "streams citations alongside the text" do
    {:ok, stream} =
      ReqLLM.stream_text(@model, context(), fixture_opts("converse_citations_streaming", @opts))

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream)

    assert_cited(response)
  end
end
