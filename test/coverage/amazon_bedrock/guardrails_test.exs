defmodule ReqLLM.Coverage.AmazonBedrock.GuardrailsTest do
  @moduledoc """
  Bedrock Guardrails coverage tests on the Converse and InvokeModel routes.

  Run with REQ_LLM_FIXTURES_MODE=record to test against the live API and record
  fixtures. Recording needs a guardrail with a denied "Weather" topic in the
  AWS_REGION the other Bedrock fixtures use (us-east-1); set BEDROCK_GUARDRAIL_ID
  and BEDROCK_GUARDRAIL_VERSION to point at it.
  Otherwise uses fixtures for fast, reliable testing.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"
  @blocked_prompt "What is the weather like in Paris today?"
  @allowed_prompt "Say hi in two words."

  @routes [
    converse: [use_converse: true],
    invoke: []
  ]

  defp guardrail_opts(route_opts) do
    [
      max_tokens: 100,
      provider_options:
        route_opts ++
          [
            guardrail_identifier: System.get_env("BEDROCK_GUARDRAIL_ID", "guardrail1234"),
            guardrail_version: System.get_env("BEDROCK_GUARDRAIL_VERSION", "DRAFT"),
            guardrail_trace: "enabled"
          ]
    ]
  end

  defp guardrail_trace(%ReqLLM.Response{provider_meta: %{trace: trace}}), do: trace["guardrail"]

  defp guardrail_trace(%ReqLLM.Response{provider_meta: meta}),
    do: meta["amazon-bedrock-trace"]["guardrail"]

  for {route, route_opts} <- @routes do
    @route_opts route_opts

    test "#{route}: generate_text blocked by the guardrail" do
      opts = fixture_opts("guardrail_#{unquote(route)}_blocked", guardrail_opts(@route_opts))

      {:ok, response} = ReqLLM.generate_text(@model, @blocked_prompt, opts)

      assert response.finish_reason == :content_filter
      assert ReqLLM.Response.text(response) == "Guardrail blocked the input."
      assert guardrail_trace(response)["actionReason"] == "Guardrail blocked."
    end

    test "#{route}: stream_text blocked by the guardrail" do
      opts =
        fixture_opts("guardrail_#{unquote(route)}_blocked_stream", guardrail_opts(@route_opts))

      {:ok, stream_response} = ReqLLM.stream_text(@model, @blocked_prompt, opts)
      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)

      assert response.finish_reason == :content_filter
      assert ReqLLM.Response.text(response) == "Guardrail blocked the input."
      assert guardrail_trace(response)["actionReason"] == "Guardrail blocked."
    end

    test "#{route}: generate_text passing the guardrail" do
      opts = fixture_opts("guardrail_#{unquote(route)}_allowed", guardrail_opts(@route_opts))

      {:ok, response} = ReqLLM.generate_text(@model, @allowed_prompt, opts)

      assert response.finish_reason == :stop
      assert ReqLLM.Response.text(response) =~ ~r/\S/
      assert guardrail_trace(response)["actionReason"] == "No action."
    end
  end

  test "Llama returns the blocked response when Bedrock omits token counts" do
    opts = fixture_opts("guardrail_invoke_blocked", guardrail_opts([]))

    {:ok, response} =
      ReqLLM.generate_text(
        "amazon_bedrock:us.meta.llama3-3-70b-instruct-v1:0",
        @blocked_prompt,
        opts
      )

    assert response.finish_reason == :content_filter
    assert ReqLLM.Response.text(response) == "Guardrail blocked the input."
  end
end
