defmodule ReqLLM.Providers.AmazonBedrock.ResponsesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Providers.AmazonBedrock.Responses
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  setup do
    {:ok, model} =
      ReqLLM.model(%{provider: :amazon_bedrock, id: "openai.gpt-5.6-terra"})

    context = ReqLLM.Context.new([ReqLLM.Context.user("What's the weather?")])

    tool =
      ReqLLM.Tool.new!(
        name: "get_weather",
        description: "Get the weather",
        parameter_schema: [
          location: [type: :string, required: true, doc: "City name"]
        ],
        callback: fn _args -> {:ok, "sunny"} end
      )

    {:ok, model: model, context: context, tool: tool}
  end

  test "formats Responses input, tools, reasoning, and token limits", %{
    context: context,
    tool: tool
  } do
    raw_body =
      Responses.format_request("openai.gpt-5.6-terra", context,
        tools: [tool],
        reasoning_effort: :high,
        max_tokens: 512,
        stream: true
      )

    assert raw_body[:model] == "openai.gpt-5.6-terra"
    refute Map.has_key?(raw_body, "model")

    body =
      raw_body
      |> Jason.encode!()
      |> Jason.decode!()

    assert [%{"role" => "user", "content" => [%{"type" => "input_text"}]}] = body["input"]
    refute Map.has_key?(body, "messages")
    assert [%{"type" => "function", "name" => "get_weather"}] = body["tools"]
    assert body["reasoning"] == %{"effort" => "high"}
    assert body["max_output_tokens"] == 512
    assert body["stream"] == true
    assert body["model"] == "openai.gpt-5.6-terra"
  end

  test "decodes buffered text and function calls", %{context: context} do
    body = %{
      "id" => "resp_123",
      "model" => "openai.gpt-5.6-terra",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "Checking now."}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_123",
          "name" => "get_weather",
          "arguments" => ~s({"location":"Boston"})
        }
      ],
      "usage" => %{"input_tokens" => 8, "output_tokens" => 12}
    }

    assert {:ok, response} =
             Responses.parse_response(body, %{
               model: "openai.gpt-5.6-terra",
               operation: :chat,
               context: context
             })

    assert [%ReqLLM.Message.ContentPart{type: :text, text: "Checking now."}] =
             response.message.content

    assert [tool_call] = response.message.tool_calls
    assert tool_call.id == "call_123"
    assert tool_call.function.name == "get_weather"
    assert Jason.decode!(tool_call.function.arguments) == %{"location" => "Boston"}
    assert response.usage.input_tokens == 8
    assert response.usage.output_tokens == 12
  end

  test "statefully decodes text and function call events", %{model: model} do
    text = %{data: %{"event" => "response.output_text.delta", "delta" => "Hello"}}

    added = %{
      data: %{
        "event" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_123",
          "name" => "get_weather"
        }
      }
    }

    arguments = %{
      data: %{
        "event" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => ~s({"location":"Boston"})
      }
    }

    done = %{
      data: %{
        "event" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_123",
          "name" => "get_weather",
          "arguments" => ~s({"location":"Boston"})
        }
      }
    }

    assert {[%ReqLLM.StreamChunk{type: :content, text: "Hello"}], state} =
             Responses.decode_stream_event(text, model, nil)

    assert {[%ReqLLM.StreamChunk{type: :tool_call}], state} =
             Responses.decode_stream_event(added, model, state)

    assert {[%ReqLLM.StreamChunk{type: :meta}], state} =
             Responses.decode_stream_event(arguments, model, state)

    assert {[], _state} = Responses.decode_stream_event(done, model, state)
  end

  test "materializes completed Mantle streams with actionable tool calls", %{
    model: model,
    context: context
  } do
    events = [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "function_call", "call_id" => "call_123", "name" => "get_weather"}
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => ~s({"location":"Boston"})
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_123",
          "status" => "completed",
          "usage" => %{"input_tokens" => 8, "output_tokens" => 12}
        }
      }
    ]

    sse = Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{Jason.encode!(&1)}\n\n")
    parser = AmazonBedrock.stream_protocol_parser(model, provider_options: [endpoint: :mantle])
    assert {:ok, events, _parser_state} = parser.(sse, nil)

    {chunks, _state} =
      Enum.reduce(events, {[], nil}, fn event, {chunks, state} ->
        event = ReqLLM.Streaming.SSE.process_sse_event(event)
        {new_chunks, state} = AmazonBedrock.decode_stream_event(event, model, state)
        {chunks ++ new_chunks, state}
      end)

    metadata =
      Enum.reduce(chunks, %{}, fn
        %ReqLLM.StreamChunk{type: :meta, metadata: metadata}, acc -> Map.merge(acc, metadata)
        _, acc -> acc
      end)

    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    stream = %StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: context
    }

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert response.finish_reason == :tool_calls
    assert [tool_call] = response.message.tool_calls
    assert tool_call.id == "call_123"
    assert tool_call.function.name == "get_weather"
    assert Jason.decode!(tool_call.function.arguments) == %{"location" => "Boston"}
    assert response.message.metadata[:response_id] == "resp_123"
    assert response.usage.input_tokens == 8
    assert response.usage.output_tokens == 12
  end
end
