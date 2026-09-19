defmodule ReqLLM.ContextPerformanceTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context

  test "list normalization does not rebuild a growing prefix" do
    first = Context.user("first")
    middle = Context.new([Context.assistant("second"), Context.user("third")])
    last = Context.system("fourth")

    {context, append_calls} =
      trace_calls({:erlang, :++, 2}, [], fn ->
        Context.normalize!([first, middle, last], validate: false)
      end)

    assert append_calls == 0
    assert context.messages == [first | middle.messages] ++ [last]
  end

  test "tool execution appends all result messages in one batch" do
    context = Context.new([Context.user("base")])

    tool_calls =
      for index <- 1..5 do
        %{id: "call_#{index}", name: "missing", arguments: %{}}
      end

    {result, append_calls} =
      trace_calls({Context, :append, 2}, [:local], fn ->
        Context.execute_and_append_tools(context, tool_calls, [])
      end)

    assert append_calls == 1
    assert Enum.map(result.messages, & &1.tool_call_id) == [nil | Enum.map(1..5, &"call_#{&1}")]
  end

  test "tool exchange appends a new assistant and its results in one batch" do
    context = Context.new([Context.user("base")])

    assistant =
      Context.assistant("",
        tool_calls: [
          {"first_tool", %{}, id: "call_1"},
          {"second_tool", %{}, id: "call_2"}
        ]
      )

    results = [
      Context.tool_result("call_2", "second_tool", "second"),
      Context.tool_result("call_1", "first_tool", "first")
    ]

    {{:ok, result}, append_calls} =
      trace_calls({Context, :append, 2}, [:local], fn ->
        Context.append_tool_exchange(context, assistant, results)
      end)

    assert append_calls == 1

    assert Enum.map(result.messages, &{&1.role, &1.tool_call_id}) == [
             {:user, nil},
             {:assistant, nil},
             {:tool, "call_1"},
             {:tool, "call_2"}
           ]
  end

  defp trace_calls(pattern, pattern_flags, fun) do
    parent = self()
    assert :erlang.trace_pattern(pattern, true, pattern_flags) >= 1

    worker =
      spawn(fn ->
        receive do
          :run ->
            result = fun.()
            send(parent, {:finished, self(), result})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn ->
      :erlang.trace_pattern(pattern, false, pattern_flags)

      if Process.alive?(worker) do
        :erlang.trace(worker, false, [:all])
        send(worker, :stop)
      end
    end)

    assert :erlang.trace(worker, true, [:call, {:tracer, parent}]) == 1
    send(worker, :run)

    assert_receive {:finished, ^worker, result}, 5_000

    delivery_ref = :erlang.trace_delivered(worker)
    call_count = count_calls(worker, delivery_ref)

    :erlang.trace(worker, false, [:call])
    send(worker, :stop)
    :erlang.trace_pattern(pattern, false, pattern_flags)

    {result, call_count}
  end

  defp count_calls(worker, delivery_ref, count \\ 0) do
    receive do
      {:trace, ^worker, :call, _call} ->
        count_calls(worker, delivery_ref, count + 1)

      {:trace_delivered, ^worker, ^delivery_ref} ->
        count
    end
  end
end
