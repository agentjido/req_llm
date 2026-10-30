defmodule ReqLLM.Coverage.AmazonBedrock.MantleGpt6Test do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:openai.gpt-6.1-sol"
  @opts [max_tokens: 64, provider_options: [endpoint: :mantle, region: "us-east-1"]]

  test "answers on the /openai/v1 Responses route" do
    {:ok, response} =
      ReqLLM.generate_text(
        @model,
        "Say hi in two words.",
        fixture_opts("mantle_responses", @opts)
      )

    assert ReqLLM.Response.text(response) =~ ~r/\S/
    assert response.usage.output_tokens > 0
  end

  test "runs on the ultrafast service tier" do
    opts = fixture_opts("mantle_ultrafast", Keyword.put(@opts, :service_tier, "ultrafast"))

    {:ok, response} = ReqLLM.generate_text(@model, "Say hi in two words.", opts)

    assert ReqLLM.Response.text(response) =~ ~r/\S/
    assert response.provider_meta["service_tier"] == "ultrafast"
  end
end
