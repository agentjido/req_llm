defmodule ReqLLM.ContextToolContinuationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Error.Validation.Error
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.ToolCall
  alias ReqLLM.ToolResult

  setup do
    first_call =
      "call_1"
      |> ToolCall.new("get_weather", ~s({"city":"Paris"}))
      |> ToolCall.put_metadata(%{thought_signature: "sig_123"})

    builtin_call = ToolCall.new_builtin("builtin_1", "web_search_call", ~s({"query":"weather"}))

    provider_native_call =
      "native_1"
      |> ToolCall.new("provider_search", ~s({"query":"weather"}))
      |> ToolCall.put_metadata(%{provider_native: :example, request_id: "req_native"})

    second_call = ToolCall.new("call_2", "get_time", ~s({"timezone":"Europe/Paris"}))

    assistant = %Message{
      role: :assistant,
      content: [ContentPart.text("I will check both.")],
      tool_calls: [first_call, builtin_call, provider_native_call, second_call],
      metadata: %{provider_native: %{response_id: "resp_123"}},
      reasoning_details: [
        %Message.ReasoningDetails{
          provider: :anthropic,
          signature: "reasoning_signature",
          format: "anthropic-v1"
        }
      ]
    }

    first_result =
      Context.tool_result(
        "call_1",
        %ToolResult{
          output: %{temperature_f: 72, internal_cursor: "cursor_123"},
          content: [ContentPart.text("72°F and sunny")],
          metadata: %{provider_native: %{request_id: "req_result_1"}}
        }
      )

    native_result =
      Context.tool_result_message(
        "provider_search",
        "native_1",
        "provider search complete",
        %{provider_native: %{request_id: "req_native_result"}}
      )

    second_result = Context.tool_result("call_2", "get_time", "10:00 CEST")
    base_context = Context.new([Context.user("Weather and time in Paris?")])

    %{
      assistant: assistant,
      base_context: base_context,
      first_result: first_result,
      native_result: native_result,
      second_result: second_result
    }
  end

  describe "append_tool_exchange/3" do
    test "appends canonical messages in assistant call order", setup do
      results = [setup.second_result, setup.native_result, setup.first_result]

      assert {:ok, context} =
               Context.append_tool_exchange(setup.base_context, setup.assistant, results)

      assert [user, assistant, first_result, native_result, second_result] = context.messages
      assert user == hd(setup.base_context.messages)
      assert assistant == setup.assistant

      assert Enum.map([first_result, native_result, second_result], & &1.tool_call_id) == [
               "call_1",
               "native_1",
               "call_2"
             ]

      assert first_result.name == "get_weather"
      assert native_result.name == "provider_search"
      assert second_result.name == "get_time"
      assert first_result.content == setup.first_result.content
      assert first_result.metadata == setup.first_result.metadata
      assert native_result.metadata == setup.native_result.metadata
      assert assistant.metadata == setup.assistant.metadata
      assert assistant.reasoning_details == setup.assistant.reasoning_details
      assert length(assistant.tool_calls) == 4
    end

    test "produces equal contexts from a message, response, or merged response context", setup do
      response = %Response{
        id: "resp_123",
        model: "test:model",
        context: setup.base_context,
        message: setup.assistant
      }

      results = [setup.second_result, setup.native_result, setup.first_result]
      merged_context = Context.merge_response(setup.base_context, response).context

      assert {:ok, from_message} =
               Context.append_tool_exchange(setup.base_context, setup.assistant, results)

      assert {:ok, from_response} =
               Context.append_tool_exchange(setup.base_context, response, results)

      assert {:ok, from_merged_context} =
               Context.append_tool_exchange(merged_context, response, results)

      assert from_message == from_response
      assert from_response == from_merged_context
      assert Enum.count(from_merged_context.messages, &(&1 == setup.assistant)) == 1
    end

    test "returns a serializable context with no live-process state", setup do
      assert {:ok, context} =
               Context.append_tool_exchange(
                 setup.base_context,
                 setup.assistant,
                 [setup.first_result, setup.native_result, setup.second_result]
               )

      assert is_binary(Jason.encode!(context))
      assert context == context |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "rejects duplicate result IDs", setup do
      assert_exchange_error(
        :duplicate_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [
            setup.first_result,
            setup.first_result,
            setup.native_result,
            setup.second_result
          ]
        )
      )
    end

    test "rejects missing results", setup do
      assert_exchange_error(
        :missing_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [setup.first_result]
        )
      )
    end

    test "rejects invalid results", setup do
      assert_exchange_error(
        :invalid_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [Context.user("not a tool result"), setup.second_result]
        )
      )

      assert_exchange_error(
        :invalid_tool_results,
        Context.append_tool_exchange(setup.base_context, setup.assistant, :not_a_list)
      )
    end

    test "rejects results for unknown calls", setup do
      unknown_result = Context.tool_result("unknown_call", "unknown_tool", "unknown")

      assert_exchange_error(
        :unknown_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [setup.first_result, unknown_result]
        )
      )
    end

    test "rejects result names that do not match their calls", setup do
      mismatched = %{setup.first_result | name: "get_time"}

      assert_exchange_error(
        :mismatched_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [mismatched, setup.native_result, setup.second_result]
        )
      )
    end

    test "rejects duplicate or invalid assistant calls", setup do
      duplicate_call = ToolCall.new("call_1", "duplicate", ~s({}))

      duplicate_assistant = %{
        setup.assistant
        | tool_calls: setup.assistant.tool_calls ++ [duplicate_call]
      }

      assert_exchange_error(
        :duplicate_tool_calls,
        Context.append_tool_exchange(
          setup.base_context,
          duplicate_assistant,
          [setup.first_result, setup.second_result]
        )
      )

      invalid_call = %ToolCall{
        id: "",
        type: "function",
        function: %{name: "broken", arguments: "{}"}
      }

      invalid_assistant = %{setup.assistant | tool_calls: [invalid_call]}

      assert_exchange_error(
        :invalid_tool_calls,
        Context.append_tool_exchange(setup.base_context, invalid_assistant, [])
      )

      raw_builtin = %{
        id: "raw_builtin",
        type: "function",
        function: %{name: "web_search_call", arguments: "{}", builtin?: true}
      }

      raw_assistant = %{setup.assistant | tool_calls: [raw_builtin]}

      assert_exchange_error(
        :invalid_tool_calls,
        Context.append_tool_exchange(setup.base_context, raw_assistant, [])
      )

      duplicate_builtin = ToolCall.new_builtin("call_1", "web_search_call", ~s({}))

      cross_kind_duplicate = %{
        setup.assistant
        | tool_calls: [hd(setup.assistant.tool_calls), duplicate_builtin]
      }

      assert_exchange_error(
        :duplicate_tool_calls,
        Context.append_tool_exchange(setup.base_context, cross_kind_duplicate, [
          setup.first_result
        ])
      )
    end

    test "rejects noncanonical tool-result content", setup do
      invalid_result = %{setup.first_result | content: [%{type: :text, text: "raw map"}]}

      assert_exchange_error(
        :invalid_tool_results,
        Context.append_tool_exchange(
          setup.base_context,
          setup.assistant,
          [invalid_result, setup.second_result]
        )
      )
    end

    test "rejects a different pending assistant tool turn", setup do
      pending =
        Context.append(
          setup.base_context,
          Context.assistant("", tool_calls: [{"other_tool", %{}, id: "other_call"}])
        )

      assert_exchange_error(
        :pending_tool_calls,
        Context.append_tool_exchange(
          pending,
          setup.assistant,
          [setup.first_result, setup.native_result, setup.second_result]
        )
      )
    end

    test "requires explicit results for provider-native calls", setup do
      provider_native_call = Enum.at(setup.assistant.tool_calls, 2)
      provider_native_assistant = %{setup.assistant | tool_calls: [provider_native_call]}

      assert_exchange_error(
        :missing_tool_results,
        Context.append_tool_exchange(setup.base_context, provider_native_assistant, [])
      )

      assert {:ok, context} =
               Context.append_tool_exchange(
                 setup.base_context,
                 provider_native_assistant,
                 [setup.native_result]
               )

      assert [_, ^provider_native_assistant, native_result] = context.messages
      assert native_result == setup.native_result
    end

    test "allows completed provider-executed calls without local results", setup do
      builtin_assistant = %{
        setup.assistant
        | tool_calls: [ToolCall.new_builtin("builtin", "web_search_call", ~s({}))]
      }

      assert {:ok, context} =
               Context.append_tool_exchange(setup.base_context, builtin_assistant, [])

      assert List.last(context.messages) == builtin_assistant

      local_result = Context.tool_result("builtin", "web_search_call", "not allowed")

      assert_exchange_error(
        :unknown_tool_results,
        Context.append_tool_exchange(setup.base_context, builtin_assistant, [local_result])
      )
    end

    test "rejects sources without tool calls or an assistant message", setup do
      empty_assistant = %{setup.assistant | tool_calls: []}

      assert_exchange_error(
        :missing_tool_calls,
        Context.append_tool_exchange(setup.base_context, empty_assistant, [])
      )

      assert_exchange_error(
        :invalid_assistant,
        Context.append_tool_exchange(setup.base_context, Context.user("wrong role"), [])
      )
    end
  end

  defp assert_exchange_error(expected_kind, result) do
    assert {:error,
            %Error{
              tag: :tool_context_continuation,
              context: error_context
            }} = result

    assert error_context[:kind] == expected_kind
  end
end
