defmodule ReqLLM.ContextToolExecutionTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Tool, ToolCall}

  defp tool(name, callback) do
    Tool.new!(name: name, description: "Review probe", parameter_schema: [], callback: callback)
  end

  test "the context helper rejects provider-owned calls and malformed arguments" do
    owner = self()

    tool =
      tool("web_search", fn _ ->
        send(owner, :local_callback)
        {:ok, "local_result"}
      end)

    calls = [
      ToolCall.new_builtin("builtin", "web_search", "{}"),
      ToolCall.new("native", "web_search", "{}")
      |> ToolCall.put_metadata(%{provider_native: :openai})
    ]

    for call <- calls do
      assert {:error, %{state: state}} = ToolCall.execute(call, [tool])
      assert state in [:provider_executed, :provider_native]
      refute_received :local_callback
      result = Context.execute_and_append_tools(Context.new([]), [call], [tool])
      refute_received :local_callback
      assert hd(result.messages).metadata[:is_error] == true
      assert hd(result.messages).tool_call_id == call.id
    end

    malformed = ToolCall.new("bad_json", "web_search", "not-json")
    result = Context.execute_and_append_tools(Context.new([]), [malformed], [tool])
    assert hd(result.messages).metadata.is_error
    refute_received :local_callback
  end

  test "application calls and legacy maps preserve result and error messages" do
    owner = self()

    tool =
      Tool.new!(
        name: "search",
        description: "Search",
        parameter_schema: [query: [type: :string, required: true]],
        callback: fn args ->
          send(owner, {:called, args})
          {:ok, %{result: args.query}}
        end
      )

    calls = [
      ToolCall.new("struct", "search", ~s({"query":"ok"})),
      %{id: "legacy", name: "search", arguments: %{query: "ok"}}
    ]

    result = Context.execute_and_append_tools(Context.new([]), calls, [tool])
    assert Enum.map(result.messages, & &1.tool_call_id) == ["struct", "legacy"]

    for message <- result.messages do
      assert message.role == :tool
      refute message.metadata[:is_error]
      assert Jason.decode!(hd(message.content).text) == %{"result" => "ok"}
      assert_receive {:called, %{query: "ok"}}
    end

    for arguments <- ["[]", ~s({"query":1})] do
      call = ToolCall.new("invalid", "search", arguments)
      error = Context.execute_and_append_tools(Context.new([]), [call], [tool])
      assert hd(error.messages).metadata.is_error
      refute_received {:called, _}
    end

    unknown = ToolCall.new("unknown", "missing", "{}")
    error = Context.execute_and_append_tools(Context.new([]), [unknown], [tool])

    assert Jason.decode!(hd(hd(error.messages).content).text) == %{
             "error" => "Tool missing not found"
           }
  end

  test "callback errors retain their previous result format" do
    tool = tool("failed", fn _ -> {:error, :permission_denied} end)

    result =
      Context.execute_and_append_tools(
        Context.new([]),
        [ToolCall.new("failed", "failed", "{}")],
        [tool]
      )

    message = hd(result.messages)
    assert message.metadata.is_error
    assert Jason.decode!(hd(message.content).text) == %{"error" => "permission_denied"}
  end
end
