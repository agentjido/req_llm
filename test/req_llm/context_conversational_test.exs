defmodule ReqLLM.ContextConversationalTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult

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

    test "creates tool result message with content parts" do
      image = ContentPart.image(<<137, 80, 78, 71>>, "image/png")
      message = Context.tool_result("call_456", [ContentPart.text("Result"), image])

      assert %Message{role: :tool, tool_call_id: "call_456"} = message
      assert [%ContentPart{type: :text}, %ContentPart{type: :image}] = message.content
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

    test "preserves structured output metadata" do
      result = %ToolResult{output: %{status: "ok"}, metadata: %{source: "tool"}}
      message = Context.tool_result_message("test_tool", "call_789", result)

      assert message.metadata[:source] == "tool"
      assert message.metadata[:tool_output] == %{status: "ok"}
      assert [%ContentPart{type: :text, text: text}] = message.content
      assert text =~ "status"
    end

    test "defaults to empty metadata" do
      message = Context.tool_result_message("test_tool", "call_456", "result")

      assert message.metadata == %{}
      assert message.name == "test_tool"
      assert message.tool_call_id == "call_456"
    end

    test "propagates is_error metadata" do
      message = Context.tool_result_message("failing_tool", "call_err", "boom", %{is_error: true})

      assert message.metadata[:is_error] == true
      assert message.role == :tool
      assert message.name == "failing_tool"
    end

    test "success path does not set is_error" do
      message = Context.tool_result_message("ok_tool", "call_ok", "all good")

      refute Map.has_key?(message.metadata, :is_error)
    end
  end

  describe "execute_and_append_tools/3" do
    setup do
      success_tool =
        ReqLLM.Tool.new!(
          name: "echo",
          description: "Echoes input",
          parameter_schema: [text: [type: :string, required: true, doc: "Text to echo"]],
          callback: fn args -> {:ok, args["text"]} end
        )

      error_tool =
        ReqLLM.Tool.new!(
          name: "fail",
          description: "Always fails",
          parameter_schema: [text: [type: :string, required: true, doc: "Ignored"]],
          callback: fn _args -> {:error, "something went wrong"} end
        )

      error_tool_result =
        ReqLLM.Tool.new!(
          name: "fail_structured",
          description: "Fails with ToolResult",
          parameter_schema: [text: [type: :string, required: true, doc: "Ignored"]],
          callback: fn _args ->
            {:error,
             %ToolResult{output: %{reason: "not found"}, content: [ContentPart.text("not found")]}}
          end
        )

      error_tool_result_conflict =
        ReqLLM.Tool.new!(
          name: "fail_structured_conflict",
          description: "Fails with conflicting ToolResult metadata",
          parameter_schema: [text: [type: :string, required: true, doc: "Ignored"]],
          callback: fn _args ->
            {:error,
             %ToolResult{
               output: %{reason: "not found"},
               content: [ContentPart.text("not found")],
               metadata: %{is_error: false, source: "tool"}
             }}
          end
        )

      context =
        Context.new([
          Context.user("Use the tools"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "echo", arguments: ~s({"text":"hello"})}
              }
            ]
          )
        ])

      %{
        success_tool: success_tool,
        error_tool: error_tool,
        error_tool_result: error_tool_result,
        error_tool_result_conflict: error_tool_result_conflict,
        context: context
      }
    end

    test "success path does not set is_error in metadata", %{success_tool: tool, context: ctx} do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_1",
          type: "function",
          function: %{name: "echo", arguments: ~s({"text":"hello"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [tool])
      tool_msg = List.last(result.messages)

      assert tool_msg.role == :tool
      assert tool_msg.name == "echo"
      refute Map.has_key?(tool_msg.metadata, :is_error)
    end

    test "error path sets is_error for generic errors", %{error_tool: tool, context: ctx} do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_1",
          type: "function",
          function: %{name: "fail", arguments: ~s({"text":"x"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [tool])
      tool_msg = List.last(result.messages)

      assert tool_msg.role == :tool
      assert tool_msg.metadata[:is_error] == true
    end

    test "error path sets is_error for ToolResult errors", %{
      error_tool_result: tool,
      context: ctx
    } do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_1",
          type: "function",
          function: %{name: "fail_structured", arguments: ~s({"text":"x"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [tool])
      tool_msg = List.last(result.messages)

      assert tool_msg.role == :tool
      assert tool_msg.metadata[:is_error] == true
    end

    test "error path keeps is_error true when ToolResult metadata conflicts", %{
      error_tool_result_conflict: tool,
      context: ctx
    } do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_1",
          type: "function",
          function: %{name: "fail_structured_conflict", arguments: ~s({"text":"x"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [tool])
      tool_msg = List.last(result.messages)

      assert tool_msg.role == :tool
      assert tool_msg.metadata[:source] == "tool"
      assert tool_msg.metadata[:is_error] == true
    end

    test "tool not found sets is_error", %{context: ctx} do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_1",
          type: "function",
          function: %{name: "nonexistent", arguments: ~s({"text":"x"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [])
      tool_msg = List.last(result.messages)

      assert tool_msg.role == :tool
      assert tool_msg.metadata[:is_error] == true
    end

    test "mixed success and error tool calls", %{
      success_tool: ok_tool,
      error_tool: fail_tool,
      context: ctx
    } do
      tool_calls = [
        %ReqLLM.ToolCall{
          id: "call_ok",
          type: "function",
          function: %{name: "echo", arguments: ~s({"text":"hello"})}
        },
        %ReqLLM.ToolCall{
          id: "call_fail",
          type: "function",
          function: %{name: "fail", arguments: ~s({"text":"x"})}
        }
      ]

      result = Context.execute_and_append_tools(ctx, tool_calls, [ok_tool, fail_tool])
      tool_messages = Enum.filter(result.messages, &(&1.role == :tool))

      assert length(tool_messages) == 2

      ok_msg = Enum.find(tool_messages, &(&1.tool_call_id == "call_ok"))
      fail_msg = Enum.find(tool_messages, &(&1.tool_call_id == "call_fail"))

      refute Map.has_key?(ok_msg.metadata, :is_error)
      assert fail_msg.metadata[:is_error] == true
    end
  end
end
