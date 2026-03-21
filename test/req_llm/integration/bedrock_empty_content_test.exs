defmodule ReqLLM.Integration.BedrockEmptyContentTest do
  @moduledoc """
  Live integration tests to probe Bedrock's handling of empty/blank assistant
  content in multi-turn tool-calling conversations.

  Tests the Converse and native Anthropic encoding paths with a Message struct
  containing an explicit empty-text ContentPart — the scenario that triggers
  Bedrock 400 errors when the encoder doesn't filter it out.

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

  # Build a context with an explicit %Message{} struct containing an empty-text
  # ContentPart in the assistant message. This bypasses Context.assistant/2's
  # to_parts normalization and hits the encoder directly.
  defp context_with_explicit_empty_text_content_part do
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
      %Message{role: :user, content: [ContentPart.text("Now what is 10 + 20?")]}
    ])
  end

  describe "explicit empty-text ContentPart in assistant message" do
    test "Converse API rejects empty text ContentBlock" do
      context = context_with_explicit_empty_text_content_part()

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
          Bedrock Converse API rejected empty text ContentPart:
          #{inspect(error, pretty: true)}
          """)
      end
    end

    test "native Anthropic API handles empty text ContentPart" do
      context = context_with_explicit_empty_text_content_part()

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
          Bedrock Anthropic (native) rejected empty text ContentPart:
          #{inspect(error, pretty: true)}
          """)
      end
    end
  end
end
