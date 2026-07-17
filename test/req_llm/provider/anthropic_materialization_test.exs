defmodule ReqLLM.Provider.AnthropicMaterializationTest do
  use ExUnit.Case, async: true

  @moduletag contract: :provider_boundary

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.Response
  alias ReqLLM.Providers.Anthropic.ResponseBuilder
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.ToolCall

  setup do
    %{model: %LLMDB.Model{provider: :anthropic, id: "claude-materialization-test"}}
  end

  test "buffered and streamed Messages data share semantic materialization", %{model: model} do
    usage = %{
      "input_tokens" => 8,
      "output_tokens" => 5,
      "cache_read_input_tokens" => 3,
      "cache_creation_input_tokens" => 2,
      "reasoning_output_tokens" => 4,
      "server_tool_use" => %{"web_search_requests" => 1}
    }

    body = %{
      "id" => "msg_123",
      "model" => model.id,
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "thinking", "thinking" => "Plan", "signature" => "sig_plan"},
        %{"type" => "text", "text" => "Answer "},
        %{
          "type" => "tool_use",
          "id" => "toolu_123",
          "name" => "lookup",
          "input" => %{"q" => "docs"}
        },
        %{"type" => "thinking", "thinking" => "Verify", "signature" => "sig_verify"},
        %{"type" => "text", "text" => "ready"}
      ],
      "stop_reason" => "tool_use",
      "stop_sequence" => nil,
      "usage" => usage
    }

    {:ok, buffered} = Response.decode_response(body, model)
    chunks = decode_events(stream_events(usage), model)

    {:ok, streamed} =
      ResponseBuilder.build_response(
        chunks,
        %{
          response_id: "msg_123",
          usage: buffered.usage,
          finish_reason: :tool_calls,
          provider_meta: %{
            "type" => "message",
            "role" => "assistant",
            "stop_sequence" => nil
          }
        },
        context: Context.new(),
        model: model
      )

    assert semantic_projection(buffered) == semantic_projection(streamed)
    assert buffered.id == streamed.id
    assert buffered.model == streamed.model
    assert streamed.context == Context.new([streamed.message])

    assert Enum.any?(chunks, fn
             %StreamChunk{type: :meta, metadata: %{terminal?: true}} -> true
             _chunk -> false
           end)

    assert Enum.any?(chunks, fn
             %StreamChunk{type: :meta, metadata: %{usage: event_usage}} ->
               event_usage.cached_tokens == 3 and event_usage.reasoning_tokens == 4

             _chunk ->
               false
           end)
  end

  test "buffered compatibility preserves exact content, metadata, and edge values", %{
    model: model
  } do
    body = %{
      "id" => "msg_ordered",
      "model" => "claude-wire",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "First"},
        %{"type" => "thinking", "thinking" => "Think", "signature" => ""},
        %{"type" => "text", "text" => "Second"},
        %{
          "type" => "tool_use",
          "id" => "toolu_ordered",
          "name" => "lookup",
          "input" => %{"q" => "docs"}
        }
      ],
      "stop_reason" => "future_stop_reason",
      "stop_sequence" => "END",
      "custom" => %{"trace" => "trace_123"},
      "usage" => %{"input_tokens" => 2, "output_tokens" => 3}
    }

    {:ok, response} = Response.decode_response(body, model)

    assert response.id == "msg_ordered"
    assert response.model == "claude-wire"
    assert response.finish_reason == :unknown
    assert response.message.metadata == %{}

    assert response.message.content == [
             %ContentPart{type: :text, text: "First", metadata: %{}},
             %ContentPart{type: :thinking, text: "Think", metadata: %{}},
             %ContentPart{type: :text, text: "Second", metadata: %{}}
           ]

    assert [detail] = response.message.reasoning_details
    assert detail.text == "Think"
    assert detail.signature == nil
    assert detail.encrypted? == false
    assert detail.provider == :anthropic
    assert detail.format == "anthropic-thinking-v1"
    assert detail.index == 0
    assert detail.provider_data == %{"type" => "thinking"}

    assert [tool_call] = response.message.tool_calls
    assert ToolCall.args_map(tool_call) == %{"q" => "docs"}
    assert ToolCall.metadata(tool_call) == %{}

    assert response.provider_meta == %{
             "type" => "message",
             "role" => "assistant",
             "stop_sequence" => "END",
             "custom" => %{"trace" => "trace_123"}
           }

    assert response.context == Context.new([response.message])
  end

  test "buffered tool-only and empty responses retain legacy message shapes", %{model: model} do
    tool_body = %{
      "id" => "msg_tool",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_empty",
          "name" => "lookup",
          "input" => %{}
        }
      ],
      "stop_reason" => "tool_use"
    }

    {:ok, tool_response} = Response.decode_response(tool_body, model)

    assert tool_response.message.content == []
    assert [%ToolCall{} = tool_call] = tool_response.message.tool_calls
    assert ToolCall.args_json(tool_call) == "{}"
    assert tool_response.context == Context.new([tool_response.message])

    empty_body = %{
      "id" => nil,
      "model" => nil,
      "content" => [%{"type" => "provider_native", "value" => "ignored"}],
      "custom" => true
    }

    {:ok, empty_response} = Response.decode_response(empty_body, model)

    assert empty_response.id == nil
    assert empty_response.model == nil
    assert empty_response.message == nil
    assert empty_response.context == Context.new()
    assert empty_response.finish_reason == nil
    assert empty_response.object == nil

    assert empty_response.usage == %{
             input_tokens: 0,
             output_tokens: 0,
             total_tokens: 0,
             cached_tokens: 0,
             reasoning_tokens: 0
           }

    assert empty_response.provider_meta == %{"custom" => true}
    assert {:error, :not_implemented} = Response.decode_response("invalid", model)
  end

  test "native provider decoding still advances the caller context", %{model: model} do
    context = Context.new([Context.user("Question")])

    request = %Req.Request{
      method: :post,
      url: URI.parse("https://api.anthropic.com/v1/messages"),
      headers: %{},
      options: %{context: context, model: model.id, operation: :chat, stream: false},
      private: %{req_llm_model: model}
    }

    http_response = %Req.Response{
      status: 200,
      headers: %{},
      body: %{
        "id" => "msg_context",
        "model" => model.id,
        "content" => [%{"type" => "text", "text" => "Answer"}],
        "stop_reason" => "end_turn"
      }
    }

    {_request, decoded} = Anthropic.decode_response({request, http_response})
    response = decoded.body

    assert response.context == Context.new(context.messages ++ [response.message])
    assert ReqLLM.Response.text(response) == "Answer"
  end

  test "StreamResponse replay helpers retain parity and cancellation", %{model: model} do
    chunks = [
      StreamChunk.thinking("Plan"),
      StreamChunk.text("Answer"),
      StreamChunk.tool_call("lookup", %{}, %{id: "toolu_replay", index: 0}),
      StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: ~s({"q":"docs"})}})
    ]

    metadata = %{
      response_id: "msg_replay",
      usage: %{
        input_tokens: 2,
        output_tokens: 1,
        total_tokens: 3,
        cached_tokens: 0,
        reasoning_tokens: 1
      },
      finish_reason: :tool_calls
    }

    to_response = stream_response(model, chunks, metadata)
    process_stream = stream_response(model, chunks, metadata)

    assert {:ok, replayed} = StreamResponse.to_response(to_response)
    assert {:ok, processed} = StreamResponse.process_stream(process_stream)
    assert semantic_projection(replayed) == semantic_projection(processed)
    assert replayed.id == "msg_replay"
    assert replayed.message.content != []
    assert [%ToolCall{} = replayed_call] = replayed.message.tool_calls
    assert ToolCall.args_map(replayed_call) == %{"q" => "docs"}

    cancelled = stream_response(model, [], %{finish_reason: :cancelled})
    assert {:ok, cancelled_response} = StreamResponse.to_response(cancelled)
    assert cancelled_response.finish_reason == :cancelled
  end

  defp decode_events(events, model) do
    {chunks, state} =
      Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {chunks, state} ->
        {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
        {chunks ++ event_chunks, next_state}
      end)

    {flush_chunks, _state} = Anthropic.flush_stream_state(model, state)
    chunks ++ flush_chunks
  end

  defp stream_events(usage) do
    [
      %{
        data: %{
          "type" => "message_start",
          "message" => %{"usage" => usage}
        }
      },
      %{
        data: %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
        }
      },
      %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Plan"}
        }
      },
      %{
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "sig_plan"}
        }
      },
      %{data: %{"type" => "content_block_stop", "index" => 0}},
      %{
        data: %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{"type" => "text", "text" => "Answer "}
        }
      },
      %{
        data: %{
          "type" => "content_block_start",
          "index" => 2,
          "content_block" => %{"type" => "tool_use", "id" => "toolu_123", "name" => "lookup"}
        }
      },
      %{
        data: %{
          "type" => "content_block_delta",
          "index" => 2,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"q":"docs"})}
        }
      },
      %{data: %{"type" => "content_block_stop", "index" => 2}},
      %{
        data: %{
          "type" => "content_block_start",
          "index" => 3,
          "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
        }
      },
      %{
        data: %{
          "type" => "content_block_delta",
          "index" => 3,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Verify"}
        }
      },
      %{
        data: %{
          "type" => "content_block_delta",
          "index" => 3,
          "delta" => %{"type" => "signature_delta", "signature" => "sig_verify"}
        }
      },
      %{data: %{"type" => "content_block_stop", "index" => 3}},
      %{
        data: %{
          "type" => "content_block_start",
          "index" => 4,
          "content_block" => %{"type" => "text", "text" => "ready"}
        }
      },
      %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => usage["output_tokens"]}
        }
      },
      %{data: %{"type" => "message_stop"}}
    ]
  end

  defp semantic_projection(response) do
    %{
      text: ReqLLM.Response.text(response),
      thinking: ReqLLM.Response.thinking(response),
      tool_calls: Enum.map(ReqLLM.Response.tool_calls(response), &ToolCall.to_map/1),
      reasoning_details: response.message.reasoning_details,
      object: response.object,
      usage: response.usage,
      finish_reason: response.finish_reason,
      provider_meta: response.provider_meta
    }
  end

  defp stream_response(model, chunks, metadata) do
    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    %StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: Context.new()
    }
  end
end
