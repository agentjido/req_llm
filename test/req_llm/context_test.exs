defmodule ReqLLM.ContextTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  describe "struct creation" do
    test "creates empty context by default" do
      context = Context.new()
      assert %Context{messages: []} = context
      assert context.messages == []
    end

    test "creates context with messages list" do
      messages = [
        Context.system("System message"),
        Context.user("Hello")
      ]

      context = Context.new(messages)

      assert %Context{messages: ^messages} = context
      assert length(context.messages) == 2
    end

    test "to_list/1 returns messages" do
      messages = [Context.system("Test"), Context.user("Hi")]
      context = Context.new(messages)

      assert Context.to_list(context) == messages
    end
  end

  describe "message constructors" do
    test "text/3 creates message with text content" do
      message = Context.text(:user, "Hello world", %{source: "test"})

      assert %Message{
               role: :user,
               content: [%ContentPart{type: :text, text: "Hello world"}],
               metadata: %{source: "test"}
             } = message
    end

    test "text/2 creates message with empty metadata" do
      message = Context.text(:assistant, "Response")

      assert message.role == :assistant
      assert message.metadata == %{}
      assert [%ContentPart{type: :text, text: "Response"}] = message.content
    end

    test "with_image/4 creates message with text and image" do
      message =
        Context.with_image(:user, "Look at this", "http://example.com/img.jpg", %{id: 123})

      assert message.role == :user
      assert message.metadata == %{id: 123}
      assert [text_part, image_part] = message.content
      assert %ContentPart{type: :text, text: "Look at this"} = text_part
      assert %ContentPart{type: :image_url, url: "http://example.com/img.jpg"} = image_part
    end

    test "with_image/3 uses empty metadata" do
      message = Context.with_image(:assistant, "Image response", "http://test.com/pic.png")

      assert message.metadata == %{}
      assert length(message.content) == 2
    end
  end

  describe "role-specific constructors" do
    test "user/2 with string content" do
      message = Context.user("Hello", %{timestamp: 123})

      assert message.role == :user
      assert message.metadata == %{timestamp: 123}
      assert [%ContentPart{type: :text, text: "Hello"}] = message.content
    end

    test "user/1 with string content and default metadata" do
      message = Context.user("Test message")

      assert message.role == :user
      assert message.metadata == %{}
    end

    test "user/2 with content parts list" do
      parts = [ContentPart.text("Hello"), ContentPart.text(" world")]
      message = Context.user(parts, %{multi: true})

      assert message.role == :user
      assert message.content == parts
      assert message.metadata == %{multi: true}
    end

    test "assistant/2 with string content" do
      message = Context.assistant("Response", %{model: "test"})

      assert message.role == :assistant
      assert message.metadata == %{model: "test"}
      assert [%ContentPart{type: :text, text: "Response"}] = message.content
    end

    test "assistant/2 with content parts list" do
      parts = [ContentPart.text("I can help")]
      message = Context.assistant(parts)

      assert message.role == :assistant
      assert message.content == parts
      assert message.metadata == %{}
    end

    test "system/2 with string content" do
      message = Context.system("You are helpful", %{version: "1.0"})

      assert message.role == :system
      assert message.metadata == %{version: "1.0"}
      assert [%ContentPart{type: :text, text: "You are helpful"}] = message.content
    end

    test "system/2 with content parts list" do
      parts = [ContentPart.text("System prompt")]
      message = Context.system(parts, %{config: true})

      assert message.role == :system
      assert message.content == parts
      assert message.metadata == %{config: true}
    end
  end

  describe "new/3 message constructor" do
    test "creates message with role, content, and metadata" do
      content = [ContentPart.text("Custom message")]
      message = Context.new(:user, content, %{custom: true})

      assert %Message{
               role: :user,
               content: ^content,
               metadata: %{custom: true}
             } = message
    end

    test "creates message with default empty metadata" do
      content = [ContentPart.text("Test")]
      message = Context.new(:assistant, content)

      assert message.metadata == %{}
    end
  end

  describe "validation" do
    test "validate/1 succeeds with valid context" do
      context =
        Context.new([
          Context.system("You are helpful"),
          Context.user("Hello"),
          Context.assistant("Hi there")
        ])

      assert {:ok, ^context} = Context.validate(context)
    end

    test "validate!/1 returns context when valid" do
      context = Context.new([Context.system("Test")])

      assert ^context = Context.validate!(context)
    end

    test "validate/1 fails with no system message" do
      context = Context.new([Context.user("Hello")])

      assert {:error, "Context should have exactly one system message, found 0"} =
               Context.validate(context)
    end

    test "validate/1 fails with multiple system messages" do
      context =
        Context.new([
          Context.system("First system"),
          Context.system("Second system"),
          Context.user("Hello")
        ])

      assert {:error, "Context should have exactly one system message, found 2"} =
               Context.validate(context)
    end

    test "validate!/1 raises with invalid context" do
      context = Context.new([Context.user("No system message")])

      assert_raise ArgumentError, ~r/Invalid context/, fn ->
        Context.validate!(context)
      end
    end

    test "validate/1 fails with invalid messages" do
      # Create context with invalid message (non-list content)
      invalid_message = %Message{role: :user, content: "not a list", metadata: %{}}
      context = Context.new([Context.system("Test"), invalid_message])

      assert {:error, "Context contains invalid messages"} = Context.validate(context)
    end
  end

  describe "Enumerable protocol" do
    setup do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello"),
          Context.assistant("Hi"),
          Context.user("Bye")
        ])

      %{context: context}
    end

    test "count/1 returns message count", %{context: context} do
      assert {:ok, 4} = Enumerable.count(context)
      assert Enum.count(context) == 4
    end

    test "member?/2 checks message membership", %{context: context} do
      [first_msg | _] = context.messages
      assert {:ok, true} = Enumerable.member?(context, first_msg)

      other_msg = Context.user("Not in context")
      assert {:ok, false} = Enumerable.member?(context, other_msg)
    end

    test "supports Enum functions", %{context: context} do
      roles = Enum.map(context, & &1.role)
      assert roles == [:system, :user, :assistant, :user]

      user_messages = Enum.filter(context, &(&1.role == :user))
      assert length(user_messages) == 2
    end

    test "slice/1 supports slicing", %{context: context} do
      assert {:ok, 4, slicer} = Enumerable.slice(context)
      assert is_function(slicer, 2)

      sliced = slicer.(1, 2)
      assert length(sliced) == 2
      assert Enum.at(sliced, 0).role == :user
    end
  end

  describe "Collectable protocol" do
    test "into/1 allows collecting messages" do
      context = Context.new([Context.system("Start")])
      new_messages = [Context.user("Hello"), Context.assistant("Hi")]

      result = Enum.into(new_messages, context)

      assert %Context{messages: messages} = result
      assert length(messages) == 3
      # New messages are reversed and prepended to original messages
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :system]
    end

    test "into/1 with empty context preserves order" do
      empty_context = Context.new()

      messages = [
        Context.system("System"),
        Context.user("First"),
        Context.assistant("Response"),
        Context.user("Second")
      ]

      result = Enum.into(messages, empty_context)

      roles = Enum.map(result.messages, & &1.role)
      # With empty context, messages are collected then reversed, preserving order
      assert roles == [:system, :user, :assistant, :user]
    end
  end

  describe "Inspect protocol" do
    test "shows message count and roles" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello"),
          Context.assistant("Hi there"),
          Context.user("Thanks")
        ])

      inspected = inspect(context)
      assert inspected == "#Context<4 msgs: system,user,assistant,user>"
    end

    test "handles empty context" do
      context = Context.new()

      inspected = inspect(context)
      assert inspected == "#Context<0 msgs: >"
    end

    test "handles single message" do
      context = Context.new([Context.system("Only system")])

      inspected = inspect(context)
      assert inspected == "#Context<1 msgs: system>"
    end
  end

  describe "edge cases" do
    test "empty context enumeration" do
      context = Context.new()

      assert Enum.empty?(context)
      assert Enum.to_list(context) == []
    end

    test "context with only system message" do
      context = Context.new([Context.system("Just system")])

      assert length(context.messages) == 1
      assert Enum.at(context.messages, 0).role == :system
    end

    test "large content handling" do
      large_text = String.duplicate("a", 10_000)
      message = Context.user(large_text)
      context = Context.new([Context.system("Test"), message])

      assert length(context.messages) == 2

      assert List.last(context.messages).content
             |> List.first()
             |> Map.get(:text)
             |> String.length() ==
               10_000
    end
  end
end
