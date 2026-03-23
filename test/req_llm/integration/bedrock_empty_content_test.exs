defmodule ReqLLM.Integration.BedrockEmptyContentTest do
  @moduledoc """
  Live integration tests to probe Bedrock's handling of empty assistant
  content in multi-turn tool-calling conversations.

  Tests both encoding paths (Converse and native Anthropic) with:
    1. Assistant message with tool_calls + empty text ContentPart
    2. Standalone assistant message with only an empty text ContentPart (no tool_calls)

  The encoder must filter the empty ContentPart in case 1 and drop the
  entire message in case 2.

  Run with:

      aws-vault exec bedrock-test -- env AWS_REGION=us-east-1 REQ_LLM_FIXTURES_MODE=record \
        mix test test/req_llm/integration/bedrock_empty_content_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Message, Message.ContentPart, ToolCall}

  @moduletag :integration
  @moduletag timeout: 120_000

  @live_ready ReqLLM.Test.Env.fixtures_mode() == :record

  if not @live_ready do
    @moduletag skip: "Run with REQ_LLM_FIXTURES_MODE=record to hit live Bedrock APIs"
  end

  @bedrock_model "amazon-bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  defp add_tool do
    ReqLLM.Tool.new!(
      name: "add",
      description: "Add two numbers",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number", "description" => "First number"},
          "b" => %{"type" => "number", "description" => "Second number"}
        },
        "required" => ["a", "b"]
      },
      callback: fn %{"a" => a, "b" => b} -> {:ok, %{result: a + b}} end
    )
  end

  # Build a context that matches the production scenario: an agent does a tool
  # call (empty text + tool_calls), gets the result, then produces an empty
  # response (empty text, no tool_calls). Context.text/3 wraps "" as
  # [ContentPart.text("")] — the encoder must handle both cases:
  #   1. assistant + tool_calls + [ContentPart.text("")] → filter the empty part
  #   2. assistant + no tool_calls + [ContentPart.text("")] → drop the message
  defp context_with_empty_assistant_after_tool_call do
    tool_call = ToolCall.new("toolu_test_001", "add", ~s({"a": 2, "b": 3}))

    Context.new([
      %Message{role: :system, content: [ContentPart.text("You are a calculator.")]},
      %Message{role: :user, content: [ContentPart.text("What is 2 + 3?")]},
      %Message{role: :assistant, content: [ContentPart.text("")], tool_calls: [tool_call]},
      %Message{
        role: :tool,
        content: [ContentPart.text("5")],
        tool_call_id: "toolu_test_001",
        name: "add"
      },
      # Empty assistant response (e.g. after no_response_needed tool) —
      # ContentPart.text("") is what Context.text/3 produces for empty strings
      %Message{role: :assistant, content: [ContentPart.text("")]},
      %Message{role: :user, content: [ContentPart.text("Now what is 10 + 20?")]}
    ])
  end

  describe "empty text in assistant messages after tool calls" do
    test "Converse API" do
      context = context_with_empty_assistant_after_tool_call()

      result =
        ReqLLM.generate_text(
          @bedrock_model,
          context,
          tools: [add_tool()],
          max_tokens: 200,
          use_converse: true
        )

      case result do
        {:ok, response} ->
          assert %ReqLLM.Response{} = response

        {:error, error} ->
          flunk("""
          Bedrock Converse API rejected empty assistant content:
          #{inspect(error, pretty: true)}
          """)
      end
    end

    test "native Anthropic API" do
      context = context_with_empty_assistant_after_tool_call()

      result =
        ReqLLM.generate_text(
          @bedrock_model,
          context,
          tools: [add_tool()],
          max_tokens: 200,
          use_converse: false
        )

      case result do
        {:ok, response} ->
          assert %ReqLLM.Response{} = response

        {:error, error} ->
          flunk("""
          Bedrock native Anthropic API rejected empty assistant content:
          #{inspect(error, pretty: true)}
          """)
      end
    end
  end
end
