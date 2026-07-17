defmodule ReqLLM.Provider.OpenAIResponsesMaterializationTest do
  use ExUnit.Case, async: true

  @moduletag contract: :provider_boundary

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.ToolCall

  setup do
    model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-responses-local",
      extra: %{wire: %{protocol: "openai_responses"}}
    }

    %{model: model}
  end

  test "buffered and streamed Responses data share semantic materialization", %{model: model} do
    context = Context.new([Context.user("Question")])

    reasoning_detail = %ReasoningDetails{
      text: "Plan",
      signature: "encrypted-plan",
      encrypted?: true,
      provider: :openai,
      format: "openai-responses-v1",
      index: 0,
      provider_data: %{"id" => "rs_1", "type" => "reasoning"}
    }

    usage = %{
      input_tokens: 5,
      output_tokens: 7,
      total_tokens: 12,
      cached_tokens: 2,
      reasoning_tokens: 3,
      tool_usage: %{"function" => %{count: 1, unit: :call}}
    }

    provider_meta = %{
      "api_type" => "responses",
      "service_tier" => "default",
      "status" => "completed"
    }

    body = %{
      "id" => "resp_123",
      "model" => "gpt-responses-wire",
      "status" => "completed",
      "service_tier" => "default",
      "output" => [
        %{
          "id" => "rs_1",
          "type" => "reasoning",
          "summary" => [%{"type" => "summary_text", "text" => "Plan"}],
          "encrypted_content" => "encrypted-plan"
        },
        %{
          "type" => "message",
          "phase" => "final_answer",
          "content" => [%{"type" => "output_text", "text" => "Answer"}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "lookup",
          "arguments" => ~s({"q":"docs"})
        }
      ],
      "usage" => %{
        "input_tokens" => 5,
        "output_tokens" => 7,
        "input_tokens_details" => %{"cached_tokens" => 2},
        "output_tokens_details" => %{"reasoning_tokens" => 3}
      }
    }

    buffered = decode(body, model, context: context)

    chunks = [
      StreamChunk.thinking("Plan"),
      StreamChunk.text("Answer"),
      StreamChunk.tool_call("lookup", %{"q" => "docs"}, %{id: "call_1", index: 0}),
      StreamChunk.meta(%{reasoning_details: [reasoning_detail]})
    ]

    {:ok, streamed} =
      ResponseBuilder.build_response(
        chunks,
        %{
          response_id: "resp_123",
          usage: usage,
          finish_reason: :tool_calls,
          provider_meta: provider_meta,
          phase: "final_answer"
        },
        context: context,
        model: model
      )

    assert semantic_projection(buffered) == semantic_projection(streamed)
    assert buffered.id == streamed.id

    assert buffered.message.metadata == %{
             response_id: "resp_123",
             phase: "final_answer"
           }

    assert streamed.message.metadata == buffered.message.metadata
    assert buffered.model == "gpt-responses-wire"
    assert streamed.model == "gpt-responses-local"
  end

  test "buffered compatibility retains legacy ordering and raw tool arguments", %{model: model} do
    context = Context.new([Context.user("Keep this")])

    body = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "summary" => "Plan"},
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => ~s({"answer":42})}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_bad",
          "name" => "malformed",
          "arguments" => "  {not-json  "
        },
        %{
          "type" => "function_call",
          "call_id" => "call_scalar",
          "name" => "scalar",
          "arguments" => ~s("draft")
        },
        %{
          "type" => "function_call",
          "call_id" => "call_empty",
          "name" => "empty",
          "arguments" => ""
        },
        %{
          "type" => "web_search_call",
          "id" => "ws_1",
          "status" => "completed",
          "action" => %{"query" => "docs", "type" => "search"}
        }
      ]
    }

    response = decode(body, model, context: context)

    assert response.id == "unknown"
    assert response.model == model.id
    assert response.finish_reason == :tool_calls
    assert response.object == nil
    assert response.message.metadata == %{response_id: nil}

    assert response.message.content == [
             %ContentPart{type: :thinking, text: "Plan", metadata: %{}},
             %ContentPart{type: :text, text: ~s({"answer":42}), metadata: %{}}
           ]

    [malformed, scalar, empty, builtin] = response.message.tool_calls

    assert ToolCall.args_json(malformed) == "{not-json"
    assert ToolCall.args_json(scalar) == ~s("draft")
    assert ToolCall.args_json(empty) == "{}"
    assert ToolCall.args_map(builtin) == %{"action" => %{"query" => "docs", "type" => "search"}}
    assert Enum.all?(response.message.tool_calls, &(ToolCall.metadata(&1) == %{}))
    assert ToolCall.builtin?(builtin)
    assert response.context == Context.new(context.messages ++ [response.message])

    legacy_stop =
      decode(
        %{
          "output" => [
            %{
              "type" => "function_call",
              "call_id" => "call_without_status",
              "name" => "lookup",
              "arguments" => "{}"
            }
          ]
        },
        model
      )

    assert legacy_stop.finish_reason == :stop

    missing_model = decode(%{"output_text" => "Answer"}, model, request_model: nil)
    assert missing_model.model == nil
  end

  test "buffered object results remain explicit without changing content", %{model: model} do
    body = %{
      "id" => "resp_object",
      "model" => "gpt-responses-wire",
      "status" => "completed",
      "output_text" => ~s({"answer":42})
    }

    response = decode(body, model, operation: :object, compiled_schema: nil)

    assert response.object == %{"answer" => 42}

    assert response.message.content == [
             %ContentPart{type: :text, text: ~s({"answer":42}), metadata: %{}}
           ]

    refute Map.has_key?(response.provider_meta, :object_parse_error)
  end

  test "Responses replay helpers use the provider materializer", %{model: model} do
    usage = %{input_tokens: 2, output_tokens: 1, total_tokens: 3}

    chunks = [
      StreamChunk.tool_call("lookup", %{"q" => "docs"}, %{id: "call_1", index: 0}),
      StreamChunk.meta(%{finish_reason: :stop, usage: usage})
    ]

    to_response =
      stream_response(model, chunks, %{
        response_id: "resp_replay",
        finish_reason: :stop,
        usage: usage
      })

    process_stream =
      stream_response(model, chunks, %{
        response_id: "resp_replay",
        finish_reason: :stop,
        usage: usage
      })

    assert {:ok, replayed} = StreamResponse.to_response(to_response)
    assert {:ok, processed} = StreamResponse.process_stream(process_stream)
    assert semantic_projection(replayed) == semantic_projection(processed)
    assert replayed.id == "resp_replay"
    assert replayed.message.metadata == %{response_id: "resp_replay"}
    assert replayed.finish_reason == :tool_calls

    cancelled = stream_response(model, [], %{finish_reason: :cancelled})
    assert {:ok, cancelled_response} = StreamResponse.to_response(cancelled)
    assert cancelled_response.finish_reason == :cancelled
  end

  defp decode(body, model, opts \\ []) do
    context = Keyword.get(opts, :context, Context.new())

    request = %Req.Request{
      method: :post,
      url: URI.parse("https://api.openai.com/v1/responses"),
      headers: %{},
      body: {:json, %{}},
      options: %{
        model: Keyword.get(opts, :request_model, model.id),
        context: context,
        operation: Keyword.get(opts, :operation, :chat),
        compiled_schema: Keyword.get(opts, :compiled_schema)
      },
      private: %{req_llm_model: model}
    }

    http_response = %Req.Response{status: 200, headers: %{}, body: body}
    {_request, decoded} = ResponsesAPI.decode_response({request, http_response})
    decoded.body
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
