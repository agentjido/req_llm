defmodule ReqLLM.Providers.OpenAIMultiAgentTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.OpenAI}

  test "HTTP, SSE, and WebSocket use the beta header and same configuration" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})
    context = Context.new([Context.user("Review the proposals")])

    opts = [
      api_key: "test-key",
      provider_options: [multi_agent: %{enabled: true, max_concurrent_subagents: 3}]
    ]

    assert {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)
    request = OpenAI.encode_body(request)
    assert Req.Request.get_header(request, "openai-beta") == ["responses_multi_agent=v1"]

    assert Jason.decode!(request.body)["multi_agent"] == %{
             "enabled" => true,
             "max_concurrent_subagents" => 3
           }

    assert {:ok, stream} = OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
    assert {"OpenAI-Beta", "responses_multi_agent=v1"} in stream.headers
    assert Jason.decode!(stream.body)["multi_agent"] == Jason.decode!(request.body)["multi_agent"]
    assert {:ok, socket} = OpenAI.attach_websocket_stream(model, context, opts)
    assert {"OpenAI-Beta", "responses_multi_agent=v1"} in socket.headers

    assert Jason.decode!(hd(socket.initial_messages))["multi_agent"] ==
             Jason.decode!(request.body)["multi_agent"]
  end

  test "disabled multi-agent does not enable the beta" do
    assert OpenAI.MultiAgent.headers([multi_agent: %{enabled: false}], "gpt-6-astra") == []
  end

  test "invalid configurations fail before an API request" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    for config <- [
          %{enabled: true, max_concurrent_subagents: 0},
          %{enabled: "true"},
          %{enabled: true, unknown: 1}
        ] do
      assert {:error, _} =
               OpenAI.prepare_request(:chat, model, "Hello",
                 api_key: "test-key",
                 provider_options: [multi_agent: config]
               )
    end

    astra = ReqLLM.model!(%{provider: :openai, id: "gpt-6-astra"})

    assert {:error, _} =
             OpenAI.prepare_request(:chat, astra, "Hello",
               api_key: "test-key",
               provider_options: [multi_agent: %{enabled: true}]
             )

    assert {:error, _} =
             OpenAI.prepare_request(:chat, model, "Hello",
               api_key: "test-key",
               provider_options: [multi_agent: %{enabled: true}, reasoning_summary: :auto]
             )
  end

  test "buffered output shows the root answer and replays every agent item" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    assert {:ok, request} =
             OpenAI.prepare_request(:chat, model, "Question",
               api_key: "test-key",
               provider_options: [store: false]
             )

    items = [
      %{
        "type" => "multi_agent_call",
        "call_id" => "spawn",
        "action" => "spawn_agent",
        "agent" => %{"agent_name" => "/root"}
      },
      %{
        "type" => "message",
        "phase" => "final_answer",
        "agent" => %{"agent_name" => "/root/reviewer"},
        "content" => [%{"type" => "output_text", "text" => "Child answer"}]
      },
      %{
        "type" => "message",
        "phase" => "final_answer",
        "agent" => %{"agent_name" => "/root"},
        "content" => [%{"type" => "output_text", "text" => "Root answer"}]
      }
    ]

    items =
      items ++
        [
          %{
            "type" => "function_call",
            "call_id" => "lookup_child",
            "name" => "lookup",
            "arguments" => "{}",
            "agent" => %{"agent_name" => "/root/reviewer"}
          }
        ]

    body = %{
      "id" => "resp_agents",
      "model" => model.id,
      "status" => "completed",
      "output" => items,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }

    {_, decoded} =
      OpenAI.ResponsesAPI.decode_response({request, Req.Response.new(status: 200, body: body)})

    response = decoded.body
    assert ReqLLM.Response.text(response) == "Root answer"
    assert [call] = response.message.tool_calls
    assert call.id == "lookup_child"
    assert ReqLLM.ToolCall.metadata(call).agent == %{"agent_name" => "/root/reviewer"}
    assert response.usage.input_tokens == 10
    assert response.usage.output_tokens == 20
    assert response.message.metadata.responses_replay.items == items

    replay =
      OpenAI.ResponsesAPI.encode_input_items(
        Context.new([response.message]),
        model.id,
        :openai,
        true
      )

    assert replay == items
  end

  test "stream deltas preserve agent attribution" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    event = %{
      data: %{
        "type" => "response.output_text.delta",
        "delta" => "Child answer",
        "output_index" => 1,
        "agent" => %{"agent_name" => "/root/reviewer"}
      }
    }

    {chunks, _state} = OpenAI.ResponsesAPI.decode_stream_event(event, model, nil)
    assert [%{metadata: %{agent: %{"agent_name" => "/root/reviewer"}}}] = chunks

    root_event = %{
      data: %{
        "type" => "response.output_text.delta",
        "delta" => "Root answer",
        "output_index" => 2,
        "agent" => %{"agent_name" => "/root"}
      }
    }

    {root_chunks, _state} = OpenAI.ResponsesAPI.decode_stream_event(root_event, model, nil)

    assert {:ok, response} =
             OpenAI.ResponsesAPI.ResponseBuilder.build_response(chunks ++ root_chunks, %{},
               model: model,
               context: Context.new([])
             )

    assert ReqLLM.Response.text(response) == "Root answer"
  end
end
