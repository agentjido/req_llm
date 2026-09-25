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
      provider_data: %{
        "id" => "rs_1",
        "type" => "reasoning",
        "summary" => [%{"type" => "summary_text", "text" => "Plan"}]
      }
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

  test "buffered Responses output surfaces annotations from output_text parts", %{model: model} do
    annotation = %{
      "type" => "url_citation",
      "url" => "https://example.com/article",
      "title" => "Example Article",
      "start_index" => 10,
      "end_index" => 20
    }

    body = %{
      "id" => "resp_ann",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => "Cited answer", "annotations" => [annotation]}
          ]
        }
      ]
    }

    response = decode(body, model)

    assert response.provider_meta["annotations"] == [annotation]
    assert ReqLLM.Response.annotations(response) == [annotation]
  end

  test "annotation.added stream events emit annotation meta chunks", %{model: model} do
    annotation = %{
      "type" => "url_citation",
      "url" => "https://example.com/article",
      "title" => "Example Article",
      "start_index" => 10,
      "end_index" => 20
    }

    event = %{
      data: %{
        "type" => "response.output_text.annotation.added",
        "annotation" => annotation,
        "annotation_index" => 0,
        "content_index" => 0,
        "output_index" => 0
      }
    }

    assert [%StreamChunk{type: :meta, metadata: %{annotations: [^annotation]}}] =
             ResponsesAPI.decode_stream_event(event, model)
  end

  test "response.completed captures annotations into provider_meta", %{model: model} do
    annotation = %{
      "type" => "url_citation",
      "url" => "https://example.com/article",
      "title" => "Example Article",
      "start_index" => 10,
      "end_index" => 20
    }

    event = %{
      data: %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_ann",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [
                %{
                  "type" => "output_text",
                  "text" => "Cited answer",
                  "annotations" => [annotation]
                }
              ]
            }
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
        }
      }
    }

    assert [%StreamChunk{type: :meta, metadata: metadata}] =
             ResponsesAPI.decode_stream_event(event, model)

    assert metadata.terminal? == true
    assert metadata.provider_meta["annotations"] == [annotation]
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
    # Function calls carry no metadata; the builtin call keeps only the
    # provider status the OTel tool span reads.
    assert Enum.map(response.message.tool_calls, &ToolCall.metadata/1) ==
             [%{}, %{}, %{}, %{status: "completed"}]

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

  for provider <- [:openai, :azure] do
    test "#{provider} preserves output order across compaction in buffered and streamed replay",
         %{model: model} do
      model = %{model | provider: unquote(provider)}
      compaction = %{"type" => "compaction", "id" => "cmp_1", "encrypted_content" => "opaque"}

      output = [
        %{
          "type" => "message",
          "role" => "assistant",
          "phase" => "commentary",
          "content" => [
            %{"type" => "output_text", "text" => "Before"}
          ]
        },
        %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [
            %{"type" => "summary_text", "text" => "Plan"}
          ],
          "encrypted_content" => "encrypted-plan"
        },
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "first",
          "arguments" => ~s({"a":1})
        },
        compaction,
        %{
          "type" => "function_call",
          "call_id" => "call_2",
          "name" => "second",
          "arguments" => ~s({"b":2})
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "phase" => "final_answer",
          "content" => [
            %{"type" => "output_text", "text" => "After"}
          ]
        }
      ]

      body = %{"id" => "resp_1", "model" => model.id, "status" => "completed", "output" => output}
      buffered = decode(body, model)

      events =
        Enum.with_index(output, fn item, index ->
          %{
            data: %{
              "type" => "response.output_item.done",
              "output_index" => index,
              "item" => item
            }
          }
        end) ++ [%{data: %{"type" => "response.completed", "response" => body}}]

      chunks = Enum.flat_map(events, &ResponsesAPI.decode_stream_event(&1, model))

      metadata =
        Enum.reduce(chunks, %{}, fn chunk, acc ->
          if chunk.type == :meta, do: Map.merge(acc, chunk.metadata), else: acc
        end)

      assert {:ok, streamed} =
               StreamResponse.to_response(stream_response(model, chunks, metadata))

      for response <- [buffered, streamed] do
        assert ResponsesAPI.encode_input_items(response.context, model.id, model.provider, true) ==
                 output

        assert Enum.map(response.message.tool_calls, &ToolCall.args_map/1) == [
                 %{"a" => 1},
                 %{"b" => 2}
               ]

        assert Enum.map(response.message.reasoning_details, & &1.provider) == [model.provider]

        content = Enum.reject(response.message.content, &(&1.type == :thinking))

        assert [
                 %ContentPart{text: "Before"},
                 %ContentPart{data: ^compaction},
                 %ContentPart{text: "After"}
               ] = content
      end

      other_provider = unquote(if provider == :openai, do: :azure, else: :openai)

      other_input =
        ResponsesAPI.encode_input_items(buffered.context, model.id, other_provider, true)

      refute Enum.any?(other_input, &(&1["type"] == "compaction"))
    end
  end

  test "summary display separates complete parts and preserves raw fragments and replay", %{
    model: model
  } do
    parts = [
      %{"type" => "summary_text", "text" => ""},
      %{"type" => "summary_text", "text" => "**Plan**\n\nUse this."},
      %{"type" => "summary_text", "text" => ""},
      %{"type" => "summary_text", "text" => "Check\n- one\n- two"}
    ]

    output = [
      %{
        "type" => "reasoning",
        "id" => "rs_1",
        "summary" => parts,
        "encrypted_content" => "enc_1"
      },
      %{
        "type" => "reasoning",
        "id" => "rs_2",
        "summary" => [
          %{"type" => "summary_text", "text" => "Finish."}
        ],
        "encrypted_content" => "enc_2"
      }
    ]

    body = %{"id" => "resp_1", "model" => model.id, "status" => "completed", "output" => output}
    buffered = decode(body, model)

    deltas =
      output
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, output_index} ->
        item["summary"]
        |> Enum.with_index()
        |> Enum.flat_map(fn {part, summary_index} ->
          {first, second} = String.split_at(part["text"], 3)

          Enum.map([first, second], fn delta ->
            %{
              data: %{
                "type" => "response.reasoning_summary_text.delta",
                "item_id" => item["id"],
                "output_index" => output_index,
                "summary_index" => summary_index,
                "delta" => delta
              }
            }
          end)
        end)
      end)

    events = deltas ++ [%{data: %{"type" => "response.completed", "response" => body}}]
    chunks = Enum.flat_map(events, &ResponsesAPI.decode_stream_event(&1, model))
    metadata = List.last(chunks).metadata
    assert {:ok, streamed} = StreamResponse.to_response(stream_response(model, chunks, metadata))

    for response <- [buffered, streamed] do
      assert ReqLLM.Response.thinking(response) ==
               "**Plan**\n\nUse this.\n\nCheck\n- one\n- two\n\nFinish."

      assert [first, second] = response.message.reasoning_details
      assert first.text == "**Plan**\n\nUse this.\n\nCheck\n- one\n- two"
      assert first.provider_data["summary"] == parts
      assert second.text == "Finish."

      replay = ResponsesAPI.encode_input_items(response.context, model.id, :openai, true)
      assert Enum.map(replay, & &1["summary"]) == Enum.map(output, & &1["summary"])
    end

    raw_text = chunks |> Enum.filter(&(&1.type == :thinking)) |> Enum.map_join(& &1.text)
    assert raw_text == "**Plan**\n\nUse this.Check\n- one\n- twoFinish."

    compaction = %{"type" => "compaction", "encrypted_content" => "opaque"}
    compacted = decode(%{body | "output" => List.insert_at(output, 1, compaction)}, model)
    assert ReqLLM.Response.thinking(compacted) == ReqLLM.Response.thinking(buffered)
  end

  test "manually built messages keep text on each side of compaction", %{model: model} do
    compaction = %{"type" => "compaction", "encrypted_content" => "opaque"}

    message = %ReqLLM.Message{
      role: :assistant,
      content: [
        ContentPart.text("Before"),
        ContentPart.provider_block(:openai, compaction),
        ContentPart.text("After")
      ]
    }

    assert [before, ^compaction, after_item] =
             ResponsesAPI.encode_input_items(Context.new([message]), model.id, :openai, true)

    assert before["content"] == [%{"type" => "output_text", "text" => "Before"}]
    assert after_item["content"] == [%{"type" => "output_text", "text" => "After"}]
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
