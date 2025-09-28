defmodule ReqLLM.ContextConversationalTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  describe "append/2" do
    test "appends single message" do
      context = Context.new([Context.system("Start")])
      message = Context.user("Hello")

      result = Context.append(context, message)

      assert %Context{messages: messages} = result
      assert length(messages) == 2
      assert List.last(messages).role == :user
    end

    test "appends multiple messages" do
      context = Context.new([Context.system("Start")])
      messages = [Context.user("Hello"), Context.assistant("Hi")]

      result = Context.append(context, messages)

      assert %Context{messages: result_messages} = result
      assert length(result_messages) == 3
      roles = Enum.map(result_messages, & &1.role)
      assert roles == [:system, :user, :assistant]
    end
  end

  describe "prepend/2" do
    test "prepends single message" do
      context = Context.new([Context.user("Hello")])
      message = Context.system("Start")

      result = Context.prepend(context, message)

      assert %Context{messages: messages} = result
      assert length(messages) == 2
      assert List.first(messages).role == :system
    end
  end

  describe "concat/2" do
    test "concatenates two contexts" do
      context1 = Context.new([Context.system("Start")])
      context2 = Context.new([Context.user("Hello"), Context.assistant("Hi")])

      result = Context.concat(context1, context2)

      assert %Context{messages: messages} = result
      assert length(messages) == 3
      roles = Enum.map(messages, & &1.role)
      assert roles == [:system, :user, :assistant]
    end
  end

  describe "push_user/2" do
    test "appends user message with string content" do
      context = Context.new([Context.system("Start")])

      result = Context.push_user(context, "Hello")

      assert %Context{messages: messages} = result
      assert length(messages) == 2
      user_message = List.last(messages)
      assert user_message.role == :user
      assert [%ContentPart{type: :text, text: "Hello"}] = user_message.content
    end

    test "appends user message with content parts" do
      context = Context.new()
      parts = [ContentPart.text("Hello"), ContentPart.image_url("https://example.com/image.jpg")]

      result = Context.push_user(context, parts, %{source: "test"})

      assert %Context{messages: [message]} = result
      assert message.role == :user
      assert message.content == parts
      assert message.metadata == %{source: "test"}
    end
  end

  describe "push_assistant/2" do
    test "appends assistant message" do
      context = Context.new([Context.user("Hello")])

      result = Context.push_assistant(context, "Hi there!")

      assert %Context{messages: messages} = result
      assert length(messages) == 2
      assistant_message = List.last(messages)
      assert assistant_message.role == :assistant
      assert [%ContentPart{type: :text, text: "Hi there!"}] = assistant_message.content
    end
  end

  describe "push_system/2" do
    test "prepends system message" do
      context = Context.new([Context.user("Hello")])

      result = Context.push_system(context, "You are helpful")

      assert %Context{messages: messages} = result
      assert length(messages) == 2
      system_message = List.first(messages)
      assert system_message.role == :system
      assert [%ContentPart{type: :text, text: "You are helpful"}] = system_message.content
    end
  end

  describe "tool/2" do
    test "creates tool message with string content" do
      message = Context.tool("Tool result", %{execution_id: "123"})

      assert %Message{
               role: :tool,
               content: [%ContentPart{type: :text, text: "Tool result"}],
               metadata: %{execution_id: "123"}
             } = message
    end

    test "creates tool message with content parts" do
      parts = [ContentPart.tool_result("call_123", %{result: "success"})]
      message = Context.tool(parts)

      assert %Message{
               role: :tool,
               content: ^parts,
               metadata: %{}
             } = message
    end
  end

  describe "assistant_tool_call/3" do
    test "creates assistant message with single tool call" do
      message = Context.assistant_tool_call("get_weather", %{location: "SF"})

      assert %Message{role: :assistant} = message

      assert [%ContentPart{type: :tool_call, tool_name: "get_weather", input: %{location: "SF"}}] =
               message.content

      # Check that ID is generated
      [tool_call] = message.content
      assert is_binary(tool_call.tool_call_id)
      assert String.length(tool_call.tool_call_id) > 0
    end

    test "accepts custom ID and metadata" do
      opts = [id: "custom_id", meta: %{source: "test"}]
      message = Context.assistant_tool_call("get_weather", %{location: "NYC"}, opts)

      assert message.metadata == %{source: "test"}
      assert [%ContentPart{tool_call_id: "custom_id"}] = message.content
    end
  end

  describe "assistant_tool_calls/2" do
    test "creates assistant message with multiple tool calls" do
      calls = [
        %{id: "call_1", name: "get_weather", input: %{location: "SF"}},
        %{id: "call_2", name: "get_time", input: %{timezone: "UTC"}}
      ]

      message = Context.assistant_tool_calls(calls, %{batch: true})

      assert %Message{role: :assistant, metadata: %{batch: true}} = message
      assert length(message.content) == 2

      [call1, call2] = message.content
      assert call1.type == :tool_call
      assert call1.tool_call_id == "call_1"
      assert call1.tool_name == "get_weather"
      assert call2.tool_call_id == "call_2"
      assert call2.tool_name == "get_time"
    end
  end

  describe "tool_result_message/4" do
    test "creates tool result message" do
      message = Context.tool_result_message("get_weather", "call_123", %{temp: 72}, %{units: "F"})

      assert %Message{
               role: :tool,
               name: "get_weather",
               tool_call_id: "call_123",
               metadata: %{units: "F"}
             } = message

      assert [
               %ContentPart{
                 type: :tool_result,
                 tool_call_id: "call_123",
                 output: %{temp: 72}
               }
             ] = message.content
    end

    test "defaults to empty metadata" do
      message = Context.tool_result_message("test_tool", "call_456", "result")

      assert message.metadata == %{}
      assert message.name == "test_tool"
      assert message.tool_call_id == "call_456"
    end
  end
end
