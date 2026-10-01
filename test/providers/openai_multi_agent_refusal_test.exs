defmodule ReqLLM.Providers.OpenAIMultiAgentRefusalTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder

  setup do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    child =
      message_item("msg_child", "/root/reviewer", [
        %{"type" => "refusal", "refusal" => "I cannot help with that."}
      ])

    root =
      message_item("msg_root", "/root", [
        %{"type" => "output_text", "text" => ~s({"name":"Alice"})}
      ])

    body = %{
      "id" => "resp_agents",
      "model" => model.id,
      "status" => "completed",
      "output" => [child, root],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }

    %{model: model, body: body}
  end

  test "buffered child refusals do not change the root finish reason", data do
    response = buffered_response(data)

    assert ReqLLM.Response.text(response) == ~s({"name":"Alice"})
    assert response.finish_reason == :stop
    assert ReqLLM.Response.refusals(response) == []
    assert response.message.metadata.responses_replay.items == data.body["output"]
  end

  test "generate_object retains the valid root object after a child refusal", data do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, data.body) end)

    assert {:ok, response} =
             ReqLLM.generate_object(
               data.model,
               "Return a person",
               [name: [type: :string, required: true]],
               api_key: "test-key",
               provider_options: [multi_agent: %{enabled: true}],
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert response.object == %{"name" => "Alice"}
    assert response.finish_reason == :stop
    assert ReqLLM.Response.refusals(response) == []
  end

  test "streamed child refusals do not change the root finish reason", data do
    response = streamed_response(data)

    assert ReqLLM.Response.text(response) == ~s({"name":"Alice"})
    assert response.finish_reason == :stop
    assert ReqLLM.Response.refusals(response) == []
    assert response.message.metadata.responses_replay.items == data.body["output"]
  end

  test "done items retain the root answer when no deltas arrive", data do
    response = streamed_response(data, :done_only)

    assert ReqLLM.Response.text(response) == ~s({"name":"Alice"})
    assert response.finish_reason == :stop
    assert ReqLLM.Response.refusals(response) == []
    assert response.message.metadata.responses_replay.items == data.body["output"]
  end

  test "buffered and streamed root refusals still report content_filter", data do
    refusal = "I cannot answer the root request."
    [child, root] = data.body["output"]
    root = Map.put(root, "content", [%{"type" => "refusal", "refusal" => refusal}])
    data = %{data | body: Map.put(data.body, "output", [child, root])}

    for response <- [buffered_response(data), streamed_response(data)] do
      assert ReqLLM.Response.text(response) == refusal
      assert response.finish_reason == :content_filter
      assert ReqLLM.Response.refusals(response) == [refusal]
      assert response.message.metadata.responses_replay.items == data.body["output"]
    end
  end

  defp message_item(id, agent_name, content) do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "phase" => "final_answer",
      "agent" => %{"agent_name" => agent_name},
      "content" => content
    }
  end

  defp buffered_response(data) do
    request = %Req.Request{options: %{req_llm_model: data.model}}

    {_, response} =
      ResponsesAPI.decode_response({request, Req.Response.new(status: 200, body: data.body)})

    response.body
  end

  defp streamed_response(data, mode \\ :deltas) do
    events =
      data.body["output"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        done = %{"type" => "response.output_item.done", "output_index" => index, "item" => item}

        case mode do
          :deltas -> message_delta_events(item, index) ++ [done]
          :done_only -> [done]
        end
      end)

    events = events ++ [%{"type" => "response.completed", "response" => data.body}]

    {chunks, _state} =
      Enum.flat_map_reduce(events, nil, fn event, state ->
        ResponsesAPI.decode_stream_event(%{data: event}, data.model, state)
      end)

    {:ok, response} =
      ResponseBuilder.build_response(chunks, List.last(chunks).metadata,
        model: data.model,
        context: ReqLLM.Context.new([])
      )

    response
  end

  defp message_delta_events(%{"content" => [part]} = item, index) do
    type = part["type"]
    added_item = Map.merge(item, %{"status" => "in_progress", "content" => []})

    [
      %{"type" => "response.output_item.added", "output_index" => index, "item" => added_item},
      %{
        "type" => "response.#{type}.delta",
        "item_id" => item["id"],
        "output_index" => index,
        "content_index" => 0,
        "agent" => item["agent"],
        "delta" => part["refusal"] || part["text"]
      }
    ]
  end
end
