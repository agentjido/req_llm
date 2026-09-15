defmodule ReqLLM.Coverage.AmazonBedrock.ConverseReasoningTest do
  @moduledoc """
  Record with REQ_LLM_FIXTURES_MODE=record and AWS_REGION=us-east-1.
  """
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  alias ReqLLM.Context
  alias ReqLLM.Message.ReasoningDetails

  @moduletag :coverage
  @moduletag provider: "amazon_bedrock"
  @moduletag timeout: 180_000

  @model "amazon_bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"
  @opts [
    max_tokens: 2048,
    reasoning_token_budget: 1024,
    provider_options: [use_converse: true]
  ]

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  test "replays signed reasoning across a tool round-trip" do
    tool =
      ReqLLM.tool(
        name: "get_balance",
        description: "Current balance for an account id",
        parameter_schema: [account_id: [type: :string, required: true]],
        callback: fn _ -> {:ok, "42"} end
      )

    context =
      Context.new([
        Context.system("Use the tool, then answer with the number only."),
        Context.user("What is the balance of account acc_1?")
      ])

    opts = @opts ++ [tools: [tool]]

    {:ok, first} =
      ReqLLM.generate_text(@model, context, fixture_opts("converse_reasoning_tool_1", opts))

    assert [call] = ReqLLM.Response.tool_calls(first)
    assert [%ReasoningDetails{signature: signature} | _] = first.message.reasoning_details
    assert is_binary(signature)

    {:ok, context} =
      Context.append_tool_exchange(first.context, first, [
        Context.tool_result(call.id, call.function.name, "42")
      ])

    {:ok, second} =
      ReqLLM.generate_text(@model, context, fixture_opts("converse_reasoning_tool_2", opts))

    assert ReqLLM.Response.text(second) =~ "42"
  end

  test "streams reasoning with its signature" do
    context = Context.new([Context.user("What is 17 times 23? Answer with the number only.")])

    {:ok, stream} =
      ReqLLM.stream_text(@model, context, fixture_opts("converse_reasoning_streaming", @opts))

    {:ok, response} = ReqLLM.StreamResponse.to_response(stream)

    assert ReqLLM.Response.text(response) =~ "391"
    assert [%ReasoningDetails{signature: signature} | _] = response.message.reasoning_details
    assert is_binary(signature)
  end
end
