defmodule ReqLLM.Providers.OpenAIAstraFeaturesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.OpenAI.Responses
  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.ToolCall

  @model "openai:gpt-6-astra"

  test "rejects unsupported effort and logprobs before HTTP or SSE dispatch" do
    model = ReqLLM.model!(@model)
    context = Context.new([Context.user("Hello")])

    for opts <- [
          [reasoning_effort: :none],
          [reasoning_effort: "minimal"],
          [provider_options: [openai_logprobs: true]],
          [provider_options: [openai_top_logprobs: 0]],
          [provider_options: [include: ["message.output_text.logprobs"]]]
        ] do
      opts = Keyword.put(opts, :api_key, "local-test-key")
      assert {:error, _} = OpenAI.prepare_request(:chat, model, context, opts)

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
      end

      assert {:error, _} = OpenAI.attach_websocket_stream(model, context, opts)
    end
  end

  test "encodes async flags on typed, flat, and nested function tools" do
    typed =
      ReqLLM.Tool.new!(
        name: "lookup",
        description: "Read a report",
        callback: fn _ -> {:ok, "report"} end,
        provider_options: [openai: [async: true]]
      )

    for tool <- [
          typed,
          %{"type" => "function", "name" => "lookup", "async" => true},
          %{type: "function", function: %{name: "lookup", async: true}}
        ] do
      assert %{"tools" => [%{"async" => true, "name" => "lookup"}]} = body("Hello", tools: [tool])
    end

    for {model, tool} <- [
          {@model, %{type: "function", name: "lookup", async: "true"}},
          {@model, %{type: "web_search", async: true}},
          {"openai:gpt-5", %{type: "function", name: "lookup", async: true}},
          {"openai:gpt-4o", %{type: "function", name: "lookup", async: true}}
        ] do
      assert {:error, _} =
               OpenAI.prepare_request(:chat, ReqLLM.model!(model), "Hello",
                 api_key: "local-test-key",
                 tools: [tool]
               )
    end

    assert %{"tools" => [%{"async" => false}]} =
             body("Hello", tools: [%{name: "lookup", async: false}])
  end

  test "buffered and streamed calls preserve async and permit delayed results" do
    model = ReqLLM.model!(@model)

    item = %{
      "type" => "function_call",
      "call_id" => "call_async",
      "name" => "lookup",
      "arguments" => ~s({"q":"docs"}),
      "async" => true
    }

    context = Context.new([Context.user("Read the report")])

    response =
      decode(
        %{
          "id" => "resp_async",
          "model" => model.id,
          "status" => "completed",
          "output" => [item],
          "output_text" => "I will keep working."
        },
        model,
        context
      )

    assert ReqLLM.Response.text(response) == "I will keep working."
    assert [call] = response.message.tool_calls
    assert ToolCall.async?(call)
    assert ToolCall.to_map(call).metadata.async
    refute ToolCall.builtin?(call)

    for added_async? <- [true, false] do
      added =
        if added_async?,
          do: Map.put(item, "arguments", ""),
          else: Map.drop(item, ["async", "arguments"])

      events = [
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => added},
        %{
          "type" => "response.function_call_arguments.delta",
          "output_index" => 0,
          "delta" => item["arguments"]
        },
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], ResponsesAPI.init_stream_state()}, fn data, {chunks, state} ->
          {next, state} = ResponsesAPI.decode_stream_event(%{data: data}, model, state)
          {chunks ++ next, state}
        end)

      {:ok, streamed} =
        ResponsesAPI.ResponseBuilder.build_response(chunks, %{}, model: model, context: context)

      assert [streamed_call] = streamed.message.tool_calls
      assert ToolCall.async?(streamed_call)
      assert ToolCall.args_map(streamed_call) == %{"q" => "docs"}
      assert streamed_call.id == "call_async"

      acc =
        ReqLLM.Provider.ChunkAccumulator.reduce(ReqLLM.Provider.ChunkAccumulator.new(), chunks)

      assert [capture_call] = ReqLLM.Provider.ChunkAccumulator.finalize_message(acc).tool_calls
      assert ToolCall.async?(capture_call)
    end

    assert {:ok, pending} = Context.append_tool_exchange(context, response, [])
    pending = Context.append(pending, Context.user("Continue while the report runs"))
    delayed = Context.append(pending, Context.tool_result(call.id, "Report is ready"))
    input = body(delayed, provider_options: [store: false])["input"]

    assert [%{"type" => "function_call", "async" => true, "call_id" => "call_async"}] =
             Enum.filter(input, &(&1["type"] == "function_call"))

    assert %{
             "type" => "function_call_output",
             "call_id" => "call_async",
             "output" => "Report is ready"
           } = List.last(input)
  end

  test "async results are optional while synchronous results remain required" do
    async_call = ToolCall.new("async", "lookup", "{}") |> ToolCall.put_metadata(%{async: true})
    sync_call = ToolCall.new("sync", "clock", "{}")

    assistant = %ReqLLM.Message{
      role: :assistant,
      content: [],
      tool_calls: [async_call, sync_call]
    }

    context = Context.new()
    assert {:error, error} = Context.append_tool_exchange(context, assistant, [])
    assert error.context[:ids] == ["sync"]

    assert {:ok, result} =
             Context.append_tool_exchange(context, assistant, [
               Context.tool_result("sync", "noon")
             ])

    assert List.last(result.messages).name == "clock"

    first = %{assistant | tool_calls: [async_call]}
    next = %{assistant | tool_calls: [sync_call]}
    assert {:ok, pending} = Context.append_tool_exchange(context, first, [])

    assert {:ok, _} =
             Context.append_tool_exchange(pending, next, [Context.tool_result("sync", "noon")])
  end

  test "configuration updates retain their position across later turns and preserve request effort" do
    update = Context.user("Think harder") |> Responses.with_reasoning_effort(:high)
    context = Context.new([Context.user("Start"), Context.assistant("Ready"), update])
    context = Context.append(context, Context.user("Continue"))
    request = body(context, reasoning_effort: :low)
    assert request["reasoning"] == %{"effort" => "low"}

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"type" => "configuration_update", "reasoning" => %{"effort" => "high"}},
             %{"role" => "user"},
             %{"role" => "user"}
           ] = request["input"]

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      Responses.with_reasoning_effort(Context.assistant("No"), :high)
    end

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      Responses.with_reasoning_effort(update, :minimal)
    end

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      ResponsesAPI.build_request_body(context, "gpt-5", [], nil)
    end
  end

  test "manual Astra history keeps reasoning at its turn and preserves the input prefix" do
    model = ReqLLM.model!(@model)
    initial = Context.new([Context.user("Start a migration plan")])

    first =
      decode(
        %{
          "id" => "resp_1",
          "model" => model.id,
          "status" => "completed",
          "output" => [
            %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "encrypted_1"}
          ],
          "output_text" => "Back up the database."
        },
        model,
        initial
      )

    updated =
      Context.append(
        first.context,
        Responses.with_reasoning_effort(Context.user("Check risks"), :high)
      )

    before = body(updated, reasoning_effort: :low, provider_options: [store: false])

    assert Enum.map(before["input"], &(&1["type"] || &1["role"])) == [
             "user",
             "reasoning",
             "assistant",
             "configuration_update",
             "user"
           ]

    second =
      decode(
        %{
          "id" => "resp_2",
          "model" => model.id,
          "status" => "completed",
          "output" => [
            %{"type" => "reasoning", "id" => "rs_2", "encrypted_content" => "encrypted_2"}
          ],
          "output_text" => "Test rollback."
        },
        model,
        updated
      )

    later = Context.append(second.context, Context.user("Continue"))
    after_update = body(later, reasoning_effort: :low, provider_options: [store: false])
    assert Enum.take(after_update["input"], length(before["input"])) == before["input"]
    assert after_update["reasoning"] == before["reasoning"]

    assert Enum.filter(after_update["input"], &(&1["type"] == "reasoning"))
           |> Enum.map(& &1["id"]) == ["rs_1", "rs_2"]
  end

  defp body(context, opts) do
    {:ok, request} =
      OpenAI.prepare_request(
        :chat,
        ReqLLM.model!(@model),
        context,
        Keyword.put(opts, :api_key, "local-test-key")
      )

    request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()
  end

  defp decode(body, model, context) do
    request = %Req.Request{
      options: %{model: model.id, context: context, operation: :chat},
      private: %{req_llm_model: model}
    }

    {_, response} =
      ResponsesAPI.decode_response({request, %Req.Response{status: 200, body: body}})

    response.body
  end
end
