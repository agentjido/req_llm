defmodule ReqLLM.Integration.ToolResultEncodingTest do
  @moduledoc """
  Integration tests for tool result encoding across different LLM providers.

  Each provider has specific requirements for encoding tool results in multi-turn
  conversations. These tests verify that tool results are correctly encoded according
  to each provider's API specifications.

  ## Covered Providers

  - **Anthropic**: Tool results must use "user" role with tool_result content blocks

  ## Future Providers

  This test suite can be extended to cover other providers as needed:
  - OpenAI
  - Google
  - Groq
  etc.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Model
  alias ReqLLM.Providers.Anthropic

  describe "Anthropic tool result encoding" do
    test "encodes complete multi-turn conversation with tool results" do
      # Multi-turn conversation flow:
      # 1. User asks a question
      # 2. Assistant calls a tool
      # 3. Tool result is returned

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      messages = [
        Context.user("What is 5 + 3?"),
        Context.assistant([
          ContentPart.text("I'll calculate that for you."),
          ContentPart.tool_call("toolu_add_123", "add", %{a: 5, b: 3})
        ]),
        Context.tool_result_message("add", "toolu_add_123", 8)
      ]

      context = Context.new(messages)
      encoded = Anthropic.Context.encode_request(context, model)

      # Verify structure
      assert length(encoded.messages) == 3
      [user_msg, assistant_msg, tool_result_msg] = encoded.messages

      # User message
      assert user_msg.role == "user"
      assert user_msg.content == "What is 5 + 3?"

      # Assistant message with tool_use
      assert assistant_msg.role == "assistant"
      assert is_list(assistant_msg.content)
      [text_block, tool_use_block] = assistant_msg.content
      assert text_block.type == "text"
      assert tool_use_block.type == "tool_use"
      assert tool_use_block.id == "toolu_add_123"
      assert tool_use_block.name == "add"

      # Tool result message - Anthropic-specific format
      # Anthropic requires role="user" (not "tool")
      assert tool_result_msg.role == "user"

      # Tool result content block
      assert is_list(tool_result_msg.content)
      [tool_result_block] = tool_result_msg.content
      assert tool_result_block.type == "tool_result"
      assert tool_result_block.tool_use_id == "toolu_add_123"
      assert tool_result_block.content == "8"
    end

    test "transforms tool role to user role for Anthropic compatibility" do
      # Anthropic API only accepts "user" or "assistant" roles
      # Tool messages must be encoded with role="user"

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      tool_result_msg = %Message{
        role: :tool,
        content: [ContentPart.tool_result("toolu_123", "result")],
        tool_call_id: "toolu_123"
      }

      context = Context.new([tool_result_msg])
      encoded = Anthropic.Context.encode_request(context, model)

      [encoded_message] = encoded.messages
      assert encoded_message.role == "user"
    end

    test "encodes tool_result content blocks correctly" do
      # Anthropic requires tool results in specific content block format

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      tool_result_part = ContentPart.tool_result("toolu_abc123", %{answer: 42, status: "success"})
      tool_msg = %Message{role: :tool, content: [tool_result_part]}

      context = Context.new([tool_msg])
      encoded = Anthropic.Context.encode_request(context, model)

      [encoded_message] = encoded.messages
      [tool_result_block] = encoded_message.content

      assert tool_result_block.type == "tool_result"
      assert tool_result_block.tool_use_id == "toolu_abc123"

      # Non-string outputs are JSON-encoded
      assert is_binary(tool_result_block.content)
      decoded = Jason.decode!(tool_result_block.content)
      assert decoded == %{"answer" => 42, "status" => "success"}
    end

    test "supports multiple tool results in single message" do
      # Multiple tool_result content blocks in one message

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      mixed_content = [
        ContentPart.text("Processing..."),
        ContentPart.tool_result("call_1", "Result 1"),
        ContentPart.tool_result("call_2", "Result 2")
      ]

      tool_msg = %Message{role: :tool, content: mixed_content}
      context = Context.new([tool_msg])
      encoded = Anthropic.Context.encode_request(context, model)

      [encoded_message] = encoded.messages
      assert length(encoded_message.content) == 3

      [text_block, result1_block, result2_block] = encoded_message.content

      assert text_block.type == "text"
      assert result1_block.type == "tool_result"
      assert result2_block.type == "tool_result"
      assert result1_block.content == "Result 1"
      assert result2_block.content == "Result 2"
    end

    test "handles string outputs without JSON encoding" do
      # String outputs pass through as-is

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      string_outputs = [
        "Simple result",
        "Multi\nline\nresult",
        ~s({"already": "json"}),
        ""
      ]

      for output <- string_outputs do
        tool_result = ContentPart.tool_result("call_1", output)
        tool_msg = %Message{role: :tool, content: [tool_result]}
        context = Context.new([tool_msg])
        encoded = Anthropic.Context.encode_request(context, model)

        [encoded_msg] = encoded.messages
        [tool_result_block] = encoded_msg.content

        assert tool_result_block.content == output
      end
    end

    test "JSON-encodes non-string outputs" do
      # Complex outputs (maps, lists, numbers, booleans) are JSON-encoded

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      complex_outputs = [
        %{status: "success", value: 42},
        [1, 2, 3],
        true,
        123
      ]

      for output <- complex_outputs do
        tool_result = ContentPart.tool_result("call_1", output)
        tool_msg = %Message{role: :tool, content: [tool_result]}
        context = Context.new([tool_msg])
        encoded = Anthropic.Context.encode_request(context, model)

        [encoded_msg] = encoded.messages
        [tool_result_block] = encoded_msg.content

        # Content should be JSON-encoded string
        assert is_binary(tool_result_block.content)
        # Verify it's valid JSON
        assert {:ok, _} = Jason.decode(tool_result_block.content)
      end
    end

    test "matches Anthropic API specification format" do
      # Verify encoding matches Anthropic's documented format
      # See: https://docs.anthropic.com/en/docs/build-with-claude/tool-use

      model = %Model{provider: :anthropic, model: "claude-3-5-sonnet-20241022"}

      tool_result = Context.tool_result_message("calculator", "toolu_123", 42)
      context = Context.new([tool_result])
      encoded = Anthropic.Context.encode_request(context, model)

      [message] = encoded.messages

      # Role must be "user"
      assert message.role == "user"

      # Content must be list of tool_result blocks
      assert is_list(message.content)
      [content_block] = message.content

      assert content_block.type == "tool_result"
      assert content_block.tool_use_id == "toolu_123"
      assert content_block.content == "42"
    end
  end
end
