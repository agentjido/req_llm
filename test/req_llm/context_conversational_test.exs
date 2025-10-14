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

  describe "tool_result/2" do
    test "creates tool result message with string content" do
      message = Context.tool_result("call_123", "Tool result")

      assert %Message{
               role: :tool,
               content: [%ContentPart{type: :text, text: "Tool result"}],
               tool_call_id: "call_123"
             } = message
    end

    test "creates tool result message with JSON output" do
      message = Context.tool_result_message("my_tool", "call_123", "success")

      assert %Message{
               role: :tool,
               content: [%ContentPart{type: :text, text: "success"}],
               tool_call_id: "call_123",
               name: "my_tool"
             } = message
    end
  end

  describe "assistant with tool_calls option" do
    test "creates assistant message with single tool call" do
      message = Context.assistant("", tool_calls: [{"get_weather", %{location: "SF"}}])

      assert %Message{role: :assistant} = message
      assert [tool_call] = message.tool_calls
      assert tool_call.function.name == "get_weather"
      assert is_binary(tool_call.id)
      assert String.length(tool_call.id) > 0
    end

    test "accepts custom ID and metadata" do
      message =
        Context.assistant("",
          tool_calls: [{"get_weather", %{location: "NYC"}, id: "custom_id"}],
          metadata: %{source: "test"}
        )

      assert message.metadata == %{source: "test"}
      assert [tool_call] = message.tool_calls
      assert tool_call.id == "custom_id"
    end

    test "creates assistant message with multiple tool calls" do
      message =
        Context.assistant("",
          tool_calls: [
            {"get_weather", %{location: "SF"}, id: "call_1"},
            {"get_time", %{timezone: "UTC"}, id: "call_2"}
          ],
          metadata: %{batch: true}
        )

      assert %Message{role: :assistant, metadata: %{batch: true}} = message
      assert length(message.tool_calls) == 2

      [call1, call2] = message.tool_calls
      assert call1.id == "call_1"
      assert call1.function.name == "get_weather"
      assert call2.id == "call_2"
      assert call2.function.name == "get_time"
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

      assert [part] = message.content
      assert part.type == :text
    end

    test "defaults to empty metadata" do
      message = Context.tool_result_message("test_tool", "call_456", "result")

      assert message.metadata == %{}
      assert message.name == "test_tool"
      assert message.tool_call_id == "call_456"
    end
  end
end
