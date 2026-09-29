defmodule ReqLLM.Coverage.AmazonBedrock.ConverseStreamErrorsTest do
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

  @model "amazon_bedrock:amazon.nova-lite-v1:0"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  test "surfaces a validation exception sent after the stream opens" do
    context =
      Context.new([
        Context.user([
          ContentPart.text("Describe this image."),
          ContentPart.image("these bytes are not a PNG image", "image/png")
        ])
      ])

    {:ok, stream} =
      ReqLLM.stream_text(
        @model,
        context,
        fixture_opts("converse_stream_validation_exception", max_tokens: 16)
      )

    assert {:error, %ReqLLM.Error.API.Request{provider_code: "validationException"}} =
             ReqLLM.StreamResponse.to_response(stream)
  end
end
