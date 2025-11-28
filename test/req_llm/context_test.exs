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
      message = Context.assistant("Response", %{id: "test"})

      assert message.role == :assistant
      assert message.metadata == %{id: "test"}
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

  describe "build/3 message constructor" do
    test "creates message with role, content, and metadata" do
      content = [ContentPart.text("Custom message")]
      message = Context.build(:user, content, %{custom: true})

      assert %Message{
               role: :user,
               content: ^content,
               metadata: %{custom: true}
             } = message
    end

    test "creates message with default empty metadata" do
      content = [ContentPart.text("Test")]
      message = Context.build(:assistant, content)

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

    test "validate/1 succeeds with no system message" do
      context = Context.new([Context.user("Hello")])

      assert {:ok, ^context} = Context.validate(context)
    end

    test "validate/1 fails with multiple system messages" do
      context =
        Context.new([
          Context.system("First system"),
          Context.system("Second system"),
          Context.user("Hello")
        ])

      assert {:error, "Context should have at most one system message, found 2"} =
               Context.validate(context)
    end

    test "validate!/1 raises with invalid context" do
      context =
        Context.new([
          Context.system("First system"),
          Context.system("Second system"),
          Context.user("Hello")
        ])

      assert_raise ReqLLM.Error.Validation.Error, fn ->
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
      # New messages are appended to original messages
      roles = Enum.map(messages, & &1.role)
      assert roles == [:system, :user, :assistant]
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

      expected = """
      #Context<4 messages:
        [0] system: "System"
        [1] user: "Hello"
        [2] assistant: "Hi there"
        [3] user: "Thanks"
      >\
      """

      assert inspected == expected
    end

    test "handles empty context" do
      context = Context.new()

      inspected = inspect(context)
      assert inspected == "#Context<0 msgs: >"
    end

    test "handles single message" do
      context = Context.new([Context.system("Only system")])

      inspected = inspect(context)
      assert inspected == "#Context<1 msgs: system:\"Only system\">"
    end
  end

  describe "normalize/2" do
    test "normalizes string input to user message" do
      {:ok, context} = Context.normalize("Hello world")

      assert %Context{messages: [message]} = context
      assert message.role == :user
      assert [%ContentPart{type: :text, text: "Hello world"}] = message.content
    end

    test "passes through Context struct unchanged" do
      original = Context.new([Context.system("System"), Context.user("Hello")])
      {:ok, context} = Context.normalize(original, validate: false)

      assert context == original
    end

    test "wraps Message struct in Context" do
      message = Context.user("Test message")
      {:ok, context} = Context.normalize(message, validate: false)

      assert %Context{messages: [^message]} = context
    end

    test "processes list of mixed types" do
      input = [
        Context.system("System prompt"),
        "User message",
        Context.assistant("Assistant response")
      ]

      {:ok, context} = Context.normalize(input)

      assert length(context.messages) == 3
      assert [system_msg, user_msg, assistant_msg] = context.messages
      assert system_msg.role == :system
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end

    @tag :parametrized_loose_maps
    test "converts loose maps" do
      test_cases = [
        {%{role: :user, content: "Map message"}, :user, "Map message"},
        {%{"role" => "user", "content" => "String key message"}, :user, "String key message"},
        {%{role: "assistant", content: "Assistant map"}, :assistant, "Assistant map"},
        {%{"role" => "system", "content" => "System map"}, :system, "System map"}
      ]

      for {input, expected_role, expected_content} <- test_cases do
        {:ok, context} = Context.normalize(input, validate: false)

        assert %Context{messages: [message]} = context
        assert message.role == expected_role
        assert [%ContentPart{type: :text, text: ^expected_content}] = message.content
      end
    end

    test "handles system prompts correctly" do
      # Adds system prompt when none exists
      {:ok, context1} =
        Context.normalize("Hello", system_prompt: "You are helpful", validate: false)

      assert length(context1.messages) == 2
      assert [system_msg1, user_msg1] = context1.messages
      assert system_msg1.role == :system
      assert [%ContentPart{type: :text, text: "You are helpful"}] = system_msg1.content
      assert user_msg1.role == :user

      # Does not add system prompt when one already exists
      input = [Context.system("Existing system"), "User message"]
      {:ok, context2} = Context.normalize(input, system_prompt: "New system", validate: false)

      assert length(context2.messages) == 2
      assert [system_msg2, _user_msg2] = context2.messages
      assert system_msg2.role == :system
      assert [%ContentPart{type: :text, text: "Existing system"}] = system_msg2.content
    end

    test "skips validation when validate: false" do
      # Context with no system message would normally fail validation
      {:ok, context} = Context.normalize("Hello", validate: false)

      assert %Context{messages: [message]} = context
      assert message.role == :user
    end

    test "validation behavior" do
      # Succeeds without system message
      {:ok, context1} = Context.normalize("Hello")
      assert %Context{messages: [message]} = context1
      assert message.role == :user

      # Succeeds with system message
      {:ok, context2} = Context.normalize("Hello", system_prompt: "You are helpful")
      assert length(context2.messages) == 2
      assert [system_msg, user_msg] = context2.messages
      assert system_msg.role == :system
      assert user_msg.role == :user

      # Fails with multiple system messages
      input = [Context.system("First system"), Context.system("Second system"), "User message"]
      {:error, reason} = Context.normalize(input)
      assert reason == "Context should have at most one system message, found 2"
    end

    test "rejects invalid loose maps when convert_loose: false" do
      input = %{role: :user, content: "Test"}
      {:error, reason} = Context.normalize(input, convert_loose: false, validate: false)

      assert reason == :invalid_prompt
    end

    test "accepts OpenAI message format with atom keys and string roles" do
      input = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      {:ok, context} = Context.normalize(input, validate: false)

      assert length(context.messages) == 3
      assert [system_msg, user_msg, assistant_msg] = context.messages

      assert system_msg.role == :system
      assert [%ContentPart{type: :text, text: "You are helpful"}] = system_msg.content

      assert user_msg.role == :user
      assert [%ContentPart{type: :text, text: "Hello"}] = user_msg.content

      assert assistant_msg.role == :assistant
      assert [%ContentPart{type: :text, text: "Hi there!"}] = assistant_msg.content
    end

    test "rejects invalid input types" do
      {:error, reason} = Context.normalize(:invalid, validate: false)
      assert reason == :invalid_prompt

      {:error, reason} = Context.normalize(123, validate: false)
      assert reason == :invalid_prompt
    end

    test "rejects loose maps with invalid role" do
      input = %{"role" => "invalid_role", "content" => "Test"}
      {:error, reason} = Context.normalize(input, validate: false)

      assert %ReqLLM.Error.Invalid.Role{} = reason
      assert reason.role == "invalid_role"
    end

    test "rejects loose maps without required keys" do
      input = %{content: "Missing role"}
      {:error, reason} = Context.normalize(input, validate: false)

      assert reason == :invalid_loose_map

      input = %{role: :user}
      {:error, reason} = Context.normalize(input, validate: false)

      assert reason == :invalid_loose_map
    end

    test "handles empty list" do
      {:ok, context} = Context.normalize([], validate: false)

      assert %Context{messages: []} = context
    end

    test "handles nested contexts in lists" do
      nested_context = Context.new([Context.user("Nested message")])
      input = [Context.system("System"), nested_context, "Another message"]

      {:ok, context} = Context.normalize(input)

      assert length(context.messages) == 3
      assert [system_msg, nested_msg, user_msg] = context.messages
      assert system_msg.role == :system
      assert nested_msg.role == :user
      assert user_msg.role == :user
    end

    test "handles empty nested context" do
      empty_context = Context.new([])

      {:error, reason} =
        Context.normalize([Context.system("System"), empty_context], validate: false)

      assert reason == :empty_context
    end
  end

  describe "normalize!/2" do
    test "returns context on success" do
      context = Context.normalize!("Hello", system_prompt: "System", validate: false)

      assert %Context{messages: messages} = context
      assert length(messages) == 2
    end

    test "raises on error" do
      assert_raise ArgumentError, ~r/Failed to normalize context/, fn ->
        Context.normalize!(:invalid)
      end
    end
  end

  describe "JSON serialization" do
    test "serializes context with all message types" do
      original_context =
        Context.new([
          Context.system("You are a helpful assistant"),
          Context.user("Hello, how are you?"),
          Context.assistant("I'm doing well, thank you! How can I help you today?"),
          Context.text(:user, "What's the weather like?", %{timestamp: "2023-01-01"})
        ])

      json_string = Jason.encode!(original_context)
      assert is_binary(json_string)

      decoded_map = Jason.decode!(json_string)

      assert is_map(decoded_map)
      assert Map.has_key?(decoded_map, "messages")
      assert length(decoded_map["messages"]) == 4

      system_msg = Enum.at(decoded_map["messages"], 0)
      assert system_msg["role"] == "system"
      assert length(system_msg["content"]) == 1

      content_part = Enum.at(system_msg["content"], 0)
      assert content_part["type"] == "text"
      assert content_part["text"] == "You are a helpful assistant"
      assert content_part["metadata"] == %{}

      user_msg = Enum.at(decoded_map["messages"], 3)
      assert user_msg["role"] == "user"
      assert user_msg["metadata"] == %{"timestamp" => "2023-01-01"}
    end

    test "serializes empty context" do
      original_context = Context.new()

      json_string = Jason.encode!(original_context)
      decoded_map = Jason.decode!(json_string)

      assert %{"messages" => []} = decoded_map
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
