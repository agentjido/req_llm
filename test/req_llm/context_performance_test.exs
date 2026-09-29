defmodule ReqLLM.ContextPerformanceTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  test "normalization reuses an all-message input list" do
    messages = Enum.map(1..100, &Context.user(Integer.to_string(&1)))

    context = Context.normalize!(messages, validate: false)

    assert :erts_debug.same(messages, context.messages)
  end

  test "normalization reuses a final expanded message segment" do
    prefix_messages = [Context.system("first"), Context.user("second")]
    final_messages = [Context.assistant("third"), Context.user("fourth")]

    context =
      Context.normalize!(
        [Context.new(prefix_messages), Context.new(final_messages)],
        validate: false
      )

    assert context.messages == prefix_messages ++ final_messages
    assert :erts_debug.same(final_messages, Enum.drop(context.messages, 2))
  end

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
    context = %Context{
      messages: [Context.user("base")],
      tools: [%{name: "sentinel"}]
    }

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
    assert result.tools == context.tools
  end

  test "tool exchange appends a new assistant and its results in one batch" do
    context = %Context{
      messages: [Context.user("base")],
      tools: [%{name: "sentinel"}]
    }

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

    assert result.tools == context.tools
  end

  test "empty append and collection do not copy history" do
    context = %Context{
      messages: Enum.map(1..100, &Context.user(Integer.to_string(&1))),
      tools: [%{name: "lookup"}]
    }

    {appended, append_calls} =
      trace_calls({:erlang, :++, 2}, [], fn -> Context.append(context, []) end)

    {collected, collect_calls} =
      trace_calls({:erlang, :++, 2}, [], fn -> Enum.into([], context) end)

    assert append_calls == 0
    assert collect_calls == 0
    assert appended == context
    assert collected == context
    assert :erts_debug.same(context, Context.append(context, []))
    assert :erts_debug.same(context, Enum.into([], context))
  end

  test "OpenAI Responses input assembly does not append growing prefixes" do
    context =
      Context.new(Enum.map(1..100, &Context.user(Integer.to_string(&1))))

    {body, append_calls} =
      trace_calls({:erlang, :++, 2}, [], fn ->
        ResponsesAPI.build_request_body(context, "gpt-5", [], nil)
      end)

    assert append_calls == 0

    assert Enum.map(body["input"], fn %{"content" => [%{"text" => text}]} -> text end) ==
             Enum.map(1..100, &Integer.to_string/1)
  end

  test "OpenAI Responses input assembly preserves mixed item order" do
    context =
      Context.new([
        Context.user("first"),
        Context.assistant("answer", tool_calls: [{"lookup", %{}, id: "call_1"}]),
        Context.tool_result("call_1", "lookup", "done"),
        Context.user("last")
      ])

    body = ResponsesAPI.build_request_body(context, "gpt-5", [], nil)

    assert Enum.map(body["input"], fn
             %{"role" => role} -> role
             %{"type" => type} -> type
           end) == ["user", "assistant", "function_call", "function_call_output", "user"]
  end

  test "Google role merging does not append growing prefixes" do
    {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

    patterns = [
      fn size ->
        Enum.map(1..size, fn index ->
          if rem(index, 2) == 0 do
            Context.assistant(Integer.to_string(index))
          else
            Context.user(Integer.to_string(index))
          end
        end)
      end,
      fn size -> Enum.map(1..size, &Context.user(Integer.to_string(&1))) end
    ]

    for messages <- patterns do
      small_request = messages.(10) |> google_request(model)
      large_request = messages.(100) |> google_request(model)

      {_small_encoded, small_calls} =
        trace_call_arguments({:erlang, :++, 2}, [], fn ->
          Google.encode_body(small_request)
        end)

      {large_encoded, large_calls} =
        trace_call_arguments({:erlang, :++, 2}, [], fn ->
          Google.encode_body(large_request)
        end)

      assert max_append_left_size(large_calls) == max_append_left_size(small_calls)

      contents = large_encoded |> ReqLLM.Test.Helpers.json_body() |> Map.fetch!("contents")

      assert contents
             |> Enum.flat_map(& &1["parts"])
             |> Enum.map(& &1["text"]) == Enum.map(1..100, &Integer.to_string/1)
    end
  end

  defp max_append_left_size(calls) do
    calls
    |> Enum.map(fn {:erlang, :++, [left, _right]} -> length(left) end)
    |> Enum.max(fn -> 0 end)
  end

  defp trace_calls(pattern, pattern_flags, fun) do
    {result, calls} = trace_call_arguments(pattern, pattern_flags, fun)
    {result, length(calls)}
  end

  defp trace_call_arguments(pattern, pattern_flags, fun) do
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
    calls = collect_calls(worker, delivery_ref)

    :erlang.trace(worker, false, [:call])
    send(worker, :stop)
    :erlang.trace_pattern(pattern, false, pattern_flags)

    {result, calls}
  end

  defp collect_calls(worker, delivery_ref, calls \\ []) do
    receive do
      {:trace, ^worker, :call, call} ->
        collect_calls(worker, delivery_ref, [call | calls])

      {:trace_delivered, ^worker, ^delivery_ref} ->
        Enum.reverse(calls)
    end
  end

  defp google_request(messages, model) do
    %Req.Request{
      options: [
        context: Context.new(messages),
        model: model.model,
        stream: false,
        operation: :chat
      ]
    }
  end
end
