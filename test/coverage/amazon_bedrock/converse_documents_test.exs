defmodule ReqLLM.Coverage.AmazonBedrock.ConverseDocumentsTest do
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

  test "answers from a PDF document" do
    pdf = File.read!("priv/examples/test.pdf")

    context =
      Context.new([
        Context.user([
          ContentPart.text("What's in this document? Quote its text."),
          ContentPart.file(pdf, "MyDocument.pdf", "application/pdf")
        ])
      ])

    {:ok, response} =
      ReqLLM.generate_text(@model, context, fixture_opts("converse_document_pdf", @opts))

    assert ReqLLM.Response.text(response) =~ "Test PDF Document"
  end
end
