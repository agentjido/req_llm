defmodule ReqLLM.ToolCallIdCompatTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.ToolCall
  alias ReqLLM.ToolCallIdCompat

  describe "apply_context_with_policy/3 with :sanitize" do
    test "sanitizes invalid IDs with ':' and '.'" do
      context =
        %Context{
          messages: [
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [
                ToolCall.new("functions.add:0", "add", ~s({"a":1,"b":2})),
                ToolCall.new("calc.mul.1", "mul", ~s({"a":2,"b":3}))
              ]
            },
            %Message{role: :tool, tool_call_id: "functions.add:0", content: "3"},
            %Message{role: :tool, tool_call_id: "calc.mul.1", content: "6"}
          ]
        }

      updated =
        ToolCallIdCompat.apply_context_with_policy(context, %{mode: :sanitize},
          tool_call_id_compat: :auto
        )

      [assistant_msg, tool_msg_1, tool_msg_2] = updated.messages
      [first_call, second_call] = assistant_msg.tool_calls

      assert first_call.id == "functions_add_0"
      assert second_call.id == "calc_mul_1"
      assert tool_msg_1.tool_call_id == "functions_add_0"
      assert tool_msg_2.tool_call_id == "calc_mul_1"
    end

    test "keeps mapping stable across assistant tool calls and tool results" do
      context =
        %Context{
          messages: [
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [ToolCall.new("functions.add:0", "add", ~s({"a":1,"b":2}))]
            },
            %Message{role: :tool, tool_call_id: "functions.add:0", content: "3"}
          ]
        }

      updated =
        ToolCallIdCompat.apply_context_with_policy(context, %{mode: :sanitize},
          tool_call_id_compat: :auto
        )

      [assistant_msg, tool_msg] = updated.messages
      [tool_call] = assistant_msg.tool_calls

      assert tool_call.id == "functions_add_0"
      assert tool_msg.tool_call_id == tool_call.id
    end

    test "avoids collisions when multiple IDs sanitize to the same value" do
      context =
        %Context{
          messages: [
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [
                ToolCall.new("a:b", "first", ~s({})),
                ToolCall.new("a.b", "second", ~s({}))
              ]
            },
            %Message{role: :tool, tool_call_id: "a:b", content: "ok"},
            %Message{role: :tool, tool_call_id: "a.b", content: "ok"}
          ]
        }

      updated =
        ToolCallIdCompat.apply_context_with_policy(context, %{mode: :sanitize},
          tool_call_id_compat: :auto
        )

      [assistant_msg, tool_msg_1, tool_msg_2] = updated.messages
      [first_call, second_call] = assistant_msg.tool_calls

      assert first_call.id == "a_b"
      assert second_call.id == "a_b_1"
      assert tool_msg_1.tool_call_id == "a_b"
      assert tool_msg_2.tool_call_id == "a_b_1"
    end

    test "enforces max-length while preserving uniqueness" do
      context =
        %Context{
          messages: [
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [
                ToolCall.new("abc:d", "first", ~s({})),
                ToolCall.new("abc.d", "second", ~s({}))
              ]
            },
            %Message{role: :tool, tool_call_id: "abc:d", content: "ok"},
            %Message{role: :tool, tool_call_id: "abc.d", content: "ok"}
          ]
        }

      updated =
        ToolCallIdCompat.apply_context_with_policy(
          context,
          %{mode: :sanitize, max_length: 5},
          tool_call_id_compat: :auto
        )

      [assistant_msg, tool_msg_1, tool_msg_2] = updated.messages
      [first_call, second_call] = assistant_msg.tool_calls

      assert first_call.id == "abc_d"
      assert second_call.id == "abc_1"
      assert String.length(first_call.id) <= 5
      assert String.length(second_call.id) <= 5
      assert tool_msg_1.tool_call_id == first_call.id
      assert tool_msg_2.tool_call_id == second_call.id
    end
  end

  describe "apply_context_with_policy/3 with :strict" do
    test "raises when context contains incompatible IDs" do
      context =
        %Context{
          messages: [
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [ToolCall.new("bad:id", "add", ~s({"a":1,"b":2}))]
            }
          ]
        }

      assert_raise ReqLLM.Error.Invalid.Parameter,
                   ~r/tool_call_id values incompatible with provider policy/,
                   fn ->
                     ToolCallIdCompat.apply_context_with_policy(
                       context,
                       %{mode: :strict, invalid_chars_regex: ~r/[^A-Za-z0-9_-]/},
                       tool_call_id_compat: :auto
                     )
                   end
    end
  end
end
