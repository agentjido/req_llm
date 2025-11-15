defmodule ReqLLM.MessageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  describe "struct creation and validation" do
    test "creates message with required role field" do
      message = %Message{role: :user}

      assert message.role == :user
      assert message.content == []
      assert message.name == nil
      assert message.tool_call_id == nil
      assert message.tool_calls == nil
      assert message.metadata == %{}
    end

    test "requires role field" do
      assert_raise ArgumentError, fn ->
        struct!(Message, %{})
      end
    end

    test "accepts all valid role types" do
      valid_roles = [:user, :assistant, :system, :tool]

      for role <- valid_roles do
        message = %Message{role: role}
        assert message.role == role
      end
    end

    test "valid?/1 returns true for valid messages" do
      message = %Message{role: :user, content: []}
      assert Message.valid?(message)

      message_with_content = %Message{
        role: :assistant,
        content: [ContentPart.text("Hello")]
      }

      assert Message.valid?(message_with_content)
    end

    test "valid?/1 returns false for invalid content" do
      invalid_message = %{role: :user, content: "not a list"}
      refute Message.valid?(invalid_message)

      refute Message.valid?(nil)
      refute Message.valid?(%{})
    end
  end

  describe "message types with content" do
    test "user message with text content" do
      content = [ContentPart.text("Hello world")]
      message = %Message{role: :user, content: content}

      assert message.role == :user
      assert message.content == content
      assert Message.valid?(message)
    end

    test "assistant message with multiple content parts" do
      content = [
        ContentPart.text("Here's the image:"),
        ContentPart.image_url("https://example.com/pic.jpg")
      ]

      message = %Message{role: :assistant, content: content}

      assert message.role == :assistant
      assert length(message.content) == 2
      assert Message.valid?(message)
    end

    test "system message with thinking content" do
      content = [ContentPart.thinking("System initialization")]
      message = %Message{role: :system, content: content}

      assert message.role == :system
      assert message.content == content
      assert Message.valid?(message)
    end

    test "tool message with text content" do
      content = [ContentPart.text("success")]

      message = %Message{
        role: :tool,
        content: content,
        tool_call_id: "call_123"
      }

      assert message.role == :tool
      assert message.tool_call_id == "call_123"
      assert Message.valid?(message)
    end
  end

  describe "message metadata and fields" do
    test "message with name field" do
      message = %Message{
        role: :assistant,
        name: "Claude",
        content: [ContentPart.text("Hello")]
      }

      assert message.name == "Claude"
      assert Message.valid?(message)
    end

    test "message with tool_call_id for tool messages" do
      message = %Message{
        role: :tool,
        tool_call_id: "call_456",
        content: [ContentPart.text("output")]
      }

      assert message.tool_call_id == "call_456"
      assert Message.valid?(message)
    end

    test "message with tool_calls array" do
      tool_calls = [
        %{id: "call_1", name: "search", args: %{query: "test"}},
        %{id: "call_2", name: "calc", args: %{expr: "2+2"}}
      ]

      message = %Message{
        role: :assistant,
        tool_calls: tool_calls,
        content: []
      }

      assert message.tool_calls == tool_calls
      assert length(message.tool_calls) == 2
      assert Message.valid?(message)
    end

    test "message with custom metadata" do
      metadata = %{
        timestamp: 1_234_567_890,
        id: "claude-3",
        source: "api",
        extra: %{nested: "value"}
      }

      message = %Message{
        role: :user,
        content: [ContentPart.text("Test")],
        metadata: metadata
      }

      assert message.metadata == metadata
      assert message.metadata.timestamp == 1_234_567_890
      assert message.metadata.extra.nested == "value"
    end
  end

  describe "complex message structures" do
    test "assistant message with tool calls and content" do
      message = %Message{
        role: :assistant,
        content: [ContentPart.text("I'll help you with that calculation.")],
        tool_calls: [%{id: "call_1", name: "calculator", args: %{op: "add", a: 1, b: 2}}],
        metadata: %{thinking: "User wants math help"}
      }

      assert message.role == :assistant
      assert length(message.content) == 1
      assert length(message.tool_calls) == 1
      assert message.metadata.thinking == "User wants math help"
      assert Message.valid?(message)
    end

    test "message with mixed content types" do
      content = [
        ContentPart.text("Look at this file:"),
        ContentPart.file("binary data", "document.pdf", "application/pdf"),
        ContentPart.text("What do you think?"),
        ContentPart.image(<<1, 2, 3>>, "image/png")
      ]

      message = %Message{role: :user, content: content}

      assert length(message.content) == 4
      assert Message.valid?(message)

      types = Enum.map(message.content, & &1.type)
      assert types == [:text, :file, :text, :image]
    end
  end

  describe "edge cases" do
    test "empty content is valid" do
      message = %Message{role: :assistant, content: []}
      assert Message.valid?(message)
      assert message.content == []
    end

    test "nil values in optional fields are valid" do
      message = %Message{
        role: :user,
        content: [ContentPart.text("Test")],
        name: nil,
        tool_call_id: nil,
        tool_calls: nil
      }

      assert Message.valid?(message)
    end
  end

  describe "Inspect implementation" do
    test "inspects message with single text content" do
      message = %Message{
        role: :user,
        content: [ContentPart.text("Hello")]
      }

      output = inspect(message)
      assert output =~ "#Message<"
      assert output =~ "user"
      assert output =~ "text"
      assert output =~ ">"
    end

    test "inspects message with multiple content types" do
      message = %Message{
        role: :assistant,
        content: [
          ContentPart.text("Here's info:"),
          ContentPart.image_url("http://example.com/pic.jpg"),
          ContentPart.thinking("I think this works")
        ]
      }

      output = inspect(message)
      assert output =~ "#Message<"
      assert output =~ "assistant"
      assert output =~ "text,image_url,thinking"
    end

    test "inspects message with empty content" do
      message = %Message{role: :system, content: []}

      output = inspect(message)
      assert output =~ "#Message<"
      assert output =~ "system"
      # Empty content summary
      assert output =~ " >"
    end

    test "inspects message with text content" do
      message = %Message{
        role: :tool,
        content: [
          ContentPart.text("result")
        ]
      }

      output = inspect(message)
      assert output =~ "#Message<"
      assert output =~ "tool"
      assert output =~ "text"
    end

    test "inspect handles all content part types" do
      content_types = [
        ContentPart.text("text"),
        ContentPart.image_url("http://example.com/img.jpg"),
        ContentPart.image(<<1, 2, 3>>, "image/png"),
        ContentPart.file("data", "file.txt", "text/plain"),
        ContentPart.thinking("thinking")
      ]

      message = %Message{role: :user, content: content_types}
      output = inspect(message)

      assert output =~ "text,image_url,image,file,thinking"
    end
  end

  describe "serialization" do
    test "round-trip JSON encoding/decoding maintains structure" do
      message = %Message{
        role: :assistant,
        content: [
          ContentPart.text("Hello"),
          ContentPart.image_url("https://example.com/pic.jpg")
        ],
        tool_calls: [%{id: "call_1", name: "search"}],
        metadata: %{priority: "high"}
      }

      json = Jason.encode!(message)
      decoded = Jason.decode!(json, keys: :atoms)

      assert String.to_atom(decoded.role) == :assistant
      assert length(decoded.content) == 2
      assert decoded.metadata.priority == "high"
    end
  end
end
