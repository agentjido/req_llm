defmodule ReqLLM.Coverage.AmazonBedrock.GuardContentTest do
  @moduledoc """
  Recording needs a guardrail with a denied "Weather" topic in us-east-1; set
  BEDROCK_GUARDRAIL_ID and BEDROCK_GUARDRAIL_VERSION, then run with
  REQ_LLM_FIXTURES_MODE=record.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"

  test "the guardrail evaluates only guarded parts" do
    context =
      Context.new([
        Context.user([
          ContentPart.text("The weather in Paris is sunny today."),
          ContentPart.text("London is the capital of UK. Tokyo is the capital of Japan.", %{
            guard_content: %{qualifiers: [:grounding_source]}
          }),
          ContentPart.text("What is the capital of Japan? Answer with the city only.", %{
            guard_content: %{qualifiers: [:query]}
          })
        ])
      ])

    opts =
      fixture_opts("guard_content_converse",
        max_tokens: 32,
        provider_options: [
          use_converse: true,
          guardrail_identifier: System.get_env("BEDROCK_GUARDRAIL_ID", "guardrail1234"),
          guardrail_version: System.get_env("BEDROCK_GUARDRAIL_VERSION", "DRAFT"),
          guardrail_trace: "enabled"
        ]
      )

    {:ok, response} = ReqLLM.generate_text(@model, context, opts)

    assert response.finish_reason == :stop
    assert ReqLLM.Response.text(response) =~ "Tokyo"

    guardrail = response.provider_meta.trace["guardrail"]
    assert guardrail["actionReason"] == "No action."

    [[output_assessment]] = Map.values(guardrail["outputAssessments"])

    assert [%{"type" => "GROUNDING", "detected" => false} | _] =
             output_assessment["contextualGroundingPolicy"]["filters"]
  end
end
