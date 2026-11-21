defmodule ReqLLM.Providers.Google.InteractionsAPI.StreamingDecoderTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.ResponseBuilder
  alias ReqLLM.StreamChunk

  @model_id "google:gemini-4-hydrogen"

  describe "stateful SSE decoding and flush" do
    test "decodes full multi-step Interactions stream from nil (2.5) and [] (4.0) states" do
      {:ok, model_25} = ReqLLM.model("google:gemini-2.5-flash")
      {:ok, model_4} = ReqLLM.model(@model_id)

      events = [
        %{
          id: "evt_1",
          event: "interaction.created",
          data: %{
            "event_type" => "interaction.created",
            "event_id" => "evt_1",
            "interaction" => %{
              "id" => "int_stream_1",
              "model" => "gemini-4-hydrogen",
              "status" => "in_progress"
            }
          }
        },
        %{
          id: "evt_2",
          event: "step.start",
          data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
        },
        %{
          id: "evt_3",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{
              "type" => "thought_summary",
              "content" => %{"type" => "text", "text" => "Planning "}
            }
          }
        },
        %{
          id: "evt_4",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_signature", "signature" => "sig_t0"}
          }
        },
        %{id: "evt_5", event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
        %{
          id: "evt_6",
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 1,
            "step" => %{"type" => "google_search_call", "id" => "gs_s1"}
          }
        },
        %{
          id: "evt_7",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{
              "type" => "google_search_call",
              "arguments" => %{"queries" => ["elixir"]}
            }
          }
        },
        %{id: "evt_8", event: "step.stop", data: %{"event_type" => "step.stop", "index" => 1}},
        %{
          id: "evt_9",
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 2,
            "step" => %{"type" => "model_output"}
          }
        },
        %{
          id: "evt_10",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 2,
            "delta" => %{"type" => "text", "text" => "Hello "}
          }
        },
        %{
          id: "evt_11",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 2,
            "delta" => %{
              "type" => "text_annotation",
              "annotations" => [%{"type" => "url_citation", "url" => "https://elixir-lang.org"}]
            }
          }
        },
        %{id: "evt_12", event: "step.stop", data: %{"event_type" => "step.stop", "index" => 2}},
        %{
          id: "evt_13",
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 3,
            "step" => %{"type" => "function_call", "id" => "fc_s1", "name" => "weather"}
          }
        },
        %{
          id: "evt_14",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 3,
            "delta" => %{"type" => "arguments_delta", "arguments" => ~s({"city":)}
          }
        },
        %{
          id: "evt_15",
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 3,
            "delta" => %{"type" => "arguments_delta", "arguments" => ~s("NYC"})}
          }
        },
        %{
          id: "evt_16",
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 3,
            "usage" => %{
              "total_input_tokens" => 12,
              "total_output_tokens" => 6,
              "total_thought_tokens" => 2,
              "total_tokens" => 20
            }
          }
        },
        %{
          id: "evt_17",
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_stream_1",
              "status" => "requires_action",
              "usage" => %{
                "total_input_tokens" => 12,
                "total_output_tokens" => 6,
                "total_thought_tokens" => 2,
                "total_tokens" => 20
              }
            }
          }
        },
        %{data: "[DONE]"}
      ]

      for model <- [model_25, model_4] do
        {chunks, final_state} =
          Enum.reduce(events, {[], Google.init_stream_state(model)}, fn ev, {acc, st} ->
            {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
            {acc ++ new_chunks, next_st}
          end)

        {flushed_chunks, flushed_state} = Google.flush_stream_state(model, final_state)
        assert flushed_chunks == []
        assert flushed_state.terminated? == true

        all_chunks = chunks ++ flushed_chunks
        assert Enum.any?(all_chunks, &match?(%StreamChunk{type: :content, text: "Hello "}, &1))

        assert Enum.any?(
                 all_chunks,
                 &match?(%StreamChunk{type: :thinking, text: "Planning "}, &1)
               )

        assert Enum.any?(all_chunks, fn
                 %StreamChunk{type: :tool_call, name: "weather", arguments: %{"city" => "NYC"}} ->
                   true

                 _ ->
                   false
               end)

        assert Enum.any?(all_chunks, fn
                 %StreamChunk{
                   type: :content_part,
                   content_part: %ContentPart{type: :provider_block}
                 } ->
                   true

                 _ ->
                   false
               end)

        meta_chunk = List.last(all_chunks)
        assert meta_chunk.metadata[:finish_reason] == :tool_calls
        assert meta_chunk.metadata[:provider_meta]["last_event_id"] == "evt_17"
        assert meta_chunk.metadata[:usage].total_tokens == 20
        assert length(meta_chunk.metadata[:google_interactions_steps]) == 4
      end
    end

    test "emits terminal error metadata on error SSE event and flushes truncated streams" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model)

      {c1, s1} =
        Google.decode_stream_event(
          %{
            event: "interaction.created",
            data: %{"event_type" => "interaction.created", "interaction" => %{"id" => "int_err"}}
          },
          model,
          init
        )

      {c2, s2} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "text", "text" => "Partial"}
            }
          },
          model,
          s1
        )

      {flushed, _} = Google.flush_stream_state(model, s2)
      meta = List.last(c1 ++ c2 ++ flushed)
      assert is_list(meta.metadata[:google_interactions_steps])

      {err_chunks, err_state} =
        Google.decode_stream_event(
          %{
            event: "error",
            data: %{
              "event_type" => "error",
              "error" => %{"code" => "rate_limit", "message" => "Quota exceeded"}
            }
          },
          model,
          s2
        )

      assert err_state.terminated? == true

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata:
                   %{
                     error: %ResponseError{reason: "Quota exceeded"},
                     google_interactions_steps: [
                       %{
                         "type" => "model_output",
                         "content" => [%{"type" => "text", "text" => "Partial"}]
                       }
                     ]
                   } = err_meta
               }
             ] = err_chunks

      {:ok, errored_built} =
        ResponseBuilder.build_response(
          c1 ++ c2 ++ err_chunks,
          err_meta,
          context: Context.new([Context.user("Hi")]),
          model: model
        )

      assert errored_built.finish_reason == :error
      assert %ResponseError{reason: "Quota exceeded"} = errored_built.error
      assert ReqLLM.Response.text(errored_built) == "Partial"

      assert [%{"type" => "model_output"}] =
               InteractionsAPI.verified_interactions_steps(errored_built.message)
    end

    test "truncated function_call streams never emit empty-args ToolCalls or :tool_calls" do
      {:ok, model} = ReqLLM.model(@model_id)

      for partial_json <- [~s({"amount": 100, "to":), ~s({"amount": 100)] do
        trunc_events = [
          %{
            event: "interaction.created",
            data: %{
              "event_type" => "interaction.created",
              "interaction" => %{"id" => "int_trunc_fc", "status" => "in_progress"}
            }
          },
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 0,
              "step" => %{"type" => "function_call", "id" => "fc_trunc", "name" => "transfer"}
            }
          },
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "arguments_delta", "arguments" => partial_json}
            }
          }
        ]

        {chunks, state} =
          Enum.reduce(trunc_events, {[], Google.init_stream_state(model)}, fn ev, {acc, st} ->
            {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
            {acc ++ new_chunks, next_st}
          end)

        {flushed, _} = Google.flush_stream_state(model, state)
        all_chunks = chunks ++ flushed

        refute Enum.any?(all_chunks, &match?(%StreamChunk{type: :tool_call}, &1))
        meta = List.last(all_chunks)
        assert meta.metadata[:finish_reason] != :tool_calls

        {:ok, built} =
          ResponseBuilder.build_response(
            all_chunks,
            meta.metadata,
            context: Context.new([Context.user("Send")]),
            model: model
          )

        assert built.finish_reason == :incomplete
        assert built.message.tool_calls == nil
      end
    end

    test "incomplete terminal status after completed function_call keeps :incomplete" do
      {:ok, model} = ReqLLM.model(@model_id)

      failed_after_fc_events = [
        %{
          event: "interaction.created",
          data: %{
            "event_type" => "interaction.created",
            "interaction" => %{"id" => "int_fail_fc", "status" => "in_progress"}
          }
        },
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{"type" => "function_call", "id" => "fc_ok", "name" => "lookup"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "arguments_delta", "arguments" => ~s({"q":"elixir"})}
          }
        },
        %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_fail_fc", "status" => "incomplete"}
          }
        }
      ]

      {fc_chunks, _} =
        Enum.reduce(failed_after_fc_events, {[], Google.init_stream_state(model)}, fn ev,
                                                                                      {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert List.last(fc_chunks).metadata[:finish_reason] == :incomplete
    end

    test "preserves wire step index order when step.stop events arrive out of order" do
      {:ok, model} = ReqLLM.model(@model_id)

      events = [
        %{
          event: "step.start",
          data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
        },
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 1,
            "step" => %{"type" => "model_output"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_signature", "signature" => "sig_0"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text", "text" => "Answer"}
          }
        },
        %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 1}},
        %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_ooo", "status" => "completed"}
          }
        }
      ]

      {chunks, _} =
        Enum.reduce(events, {[], Google.init_stream_state(model)}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      steps = List.last(chunks).metadata[:google_interactions_steps]
      assert Enum.map(steps, & &1["type"]) == ["thought", "model_output"]
    end

    test "ignores empty usage, preserves start payloads, interleaved blocks, and nil model" do
      {:ok, model} = ReqLLM.model(@model_id)

      events = [
        %{
          event: "interaction.created",
          data: %{
            "event_type" => "interaction.created",
            "interaction" => %{
              "id" => "int_edge",
              "agent" => "deep-research-pro",
              "status" => "in_progress"
            }
          }
        },
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{
              "type" => "thought",
              "summary" => [%{"type" => "text", "text" => "Initial thought"}],
              "signature" => "sig_start"
            }
          }
        },
        %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 1,
            "step" => %{
              "type" => "model_output",
              "content" => [%{"type" => "text", "text" => "Lead "}]
            }
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text_annotation", "annotations" => [%{"id" => "a1"}]}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{
              "type" => "image",
              "data" => Base.encode64(<<1, 2, 3>>),
              "mime_type" => "image/png"
            }
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text", "text" => "Tail"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{
              "type" => "text",
              "text" => nil,
              "annotations" => [%{"id" => "a2"}]
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 1,
            "usage" => %{
              "total_input_tokens" => 10,
              "total_output_tokens" => 5,
              "total_tokens" => 15
            }
          }
        },
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 2,
            "step" => %{"type" => "code_execution_result", "id" => "ce_1", "output" => "line1\n"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 2,
            "delta" => %{"type" => "code_execution_result", "id" => "ce_1", "output" => "line2"}
          }
        },
        %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 2}},
        %{
          event: "interaction.status_update",
          data: %{
            "event_type" => "interaction.status_update",
            "status" => "in_progress",
            "usage" => %{}
          }
        },
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_edge",
              "agent" => "deep-research-pro",
              "status" => "completed",
              "usage" => %{}
            }
          }
        }
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], InteractionsAPI.init_stream_state(nil)}, fn ev, {acc, st} ->
          {new_chunks, next_st} = InteractionsAPI.decode_stream_event(ev, nil, st)
          {acc ++ new_chunks, next_st}
        end)

      assert Enum.any?(
               chunks,
               &match?(%StreamChunk{type: :thinking, text: "Initial thought"}, &1)
             )

      assert Enum.any?(chunks, &match?(%StreamChunk{type: :content, text: "Lead "}, &1))
      assert Enum.any?(chunks, &match?(%StreamChunk{type: :content, text: "Tail"}, &1))

      meta_chunk = List.last(chunks)
      assert meta_chunk.metadata[:response_model] == "deep-research-pro"
      assert meta_chunk.metadata[:provider_meta]["agent"] == "deep-research-pro"
      assert meta_chunk.metadata[:usage].total_tokens == 15

      assert meta_chunk.metadata[:provider_meta]["google_usage"] == %{
               "total_input_tokens" => 10,
               "total_output_tokens" => 5,
               "total_tokens" => 15
             }

      [thought_step, model_output_step, ce_step] = meta_chunk.metadata[:google_interactions_steps]
      assert thought_step["signature"] == "sig_start"
      assert ce_step["id"] == "ce_1"
      assert ce_step["output"] == "line1\nline2"

      assert [
               %{"type" => "text", "text" => "Lead ", "annotations" => [%{"id" => "a1"}]},
               %{"type" => "image"},
               %{"type" => "text", "text" => "Tail", "annotations" => [%{"id" => "a2"}]}
             ] = model_output_step["content"]

      {:ok, built} =
        ResponseBuilder.build_response(
          chunks,
          meta_chunk.metadata,
          context: Context.new([Context.user("Go")]),
          model: model
        )

      assert ReqLLM.Response.annotations(built) == [%{"id" => "a1"}, %{"id" => "a2"}]
    end

    test "supports stateless 2-arity decode_stream_event/2 for signatures and tool calls" do
      {:ok, model} = ReqLLM.model(@model_id)

      sig_chunks =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "thought_signature", "signature" => "sig_stateless"}
            }
          },
          model
        )

      assert [%StreamChunk{type: :thinking, metadata: %{signature: "sig_stateless"}}] = sig_chunks

      stop_chunks =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 1,
              "step" => %{
                "type" => "function_call",
                "id" => "fc_stateless",
                "name" => "lookup",
                "arguments" => %{"q" => "hi"}
              }
            }
          },
          model
        )

      assert [%StreamChunk{type: :tool_call, name: "lookup", arguments: %{"q" => "hi"}}] =
               stop_chunks
    end

    test "detects prefixed and unwrapped SSE events and initializes from [] state" do
      {:ok, model} = ReqLLM.model(@model_id)

      assert InteractionsAPI.stream_event?(%{event: "interaction.future_event", data: "{}"})

      assert InteractionsAPI.stream_event?(%{
               data: ~s({"event_type":"step.future_heartbeat"})
             })

      assert InteractionsAPI.stream_event?(%{"event_type" => "interaction.created"})

      {chunks_from_list, state_from_list} =
        Google.decode_stream_event(
          %{
            "event_type" => "interaction.created",
            "interaction" => %{"id" => "int_ls", "status" => "in_progress"}
          },
          model,
          []
        )

      assert [%StreamChunk{type: :meta, metadata: %{response_id: "int_ls"}}] = chunks_from_list
      assert state_from_list.status == "in_progress"
    end

    test "tracks interaction ID across stateful and stateless function steps" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model)

      {c1, s1} =
        Google.decode_stream_event(
          %{
            event: "interaction.created",
            data: %{"interaction" => %{"id" => "int_hdr_only"}}
          },
          model,
          init
        )

      assert [%StreamChunk{type: :meta, metadata: %{response_id: "int_hdr_only"}}] = c1

      {c2, s2} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "index" => 0,
              "step" => %{
                "type" => "function_result",
                "call_id" => "c_prev",
                "name" => "tool_x",
                "result" => "ok"
              }
            }
          },
          model,
          s1
        )

      assert c2 == []

      {c3, s3} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "index" => 1,
              "step" => %{
                "type" => "function_call",
                "name" => "follow_up",
                "arguments" => %{"x" => 1}
              }
            }
          },
          model,
          s2
        )

      assert [%StreamChunk{type: :tool_call, metadata: %{id: "call_int_hdr_only_1"}}] = c3
      assert s3.terminated? == false

      assert [] =
               Google.decode_stream_event(
                 %{
                   event: "step.stop",
                   data: %{
                     "index" => 0,
                     "step" => %{
                       "type" => "function_result",
                       "call_id" => "c1",
                       "name" => "t",
                       "result" => "done"
                     }
                   }
                 },
                 model
               )

      assert [%StreamChunk{type: :tool_call, metadata: %{id: "call_2"}}] =
               Google.decode_stream_event(
                 %{
                   event: "step.stop",
                   data: %{
                     "index" => 2,
                     "step" => %{"type" => "function_call", "name" => "t2", "arguments" => %{}}
                   }
                 },
                 model
               )
    end

    test "slices completed snapshot steps to current turn after prior tool results" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model)

      {done_chunks, _final_s} =
        Google.decode_stream_event(
          %{
            event: "interaction.completed",
            data: %{
              "interaction" => %{
                "id" => "int_hdr_only",
                "status" => "completed",
                "steps" => [
                  %{"type" => "user_input", "content" => "Hi"},
                  %{
                    "type" => "function_call",
                    "id" => "call_prev_done",
                    "name" => "old_fn",
                    "arguments" => %{}
                  },
                  %{
                    "type" => "function_result",
                    "call_id" => "call_prev_done",
                    "name" => "old_fn",
                    "result" => "42"
                  },
                  %{
                    "type" => "model_output",
                    "content" => [%{"type" => "text", "text" => "Final streamed reply"}]
                  }
                ]
              }
            }
          },
          model,
          init
        )

      terminal_meta = List.last(done_chunks).metadata
      assert terminal_meta[:finish_reason] == :stop

      assert terminal_meta[:google_interactions_steps] == [
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "text", "text" => "Final streamed reply"}]
               }
             ]
    end

    test "decodes mid-step resume function_call and ignores unnamed partial calls" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {[], s_delta} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "arguments_delta", "arguments" => ~s({"city":"SF"})}
            }
          },
          model,
          init
        )

      {fc_chunks, s_fc_stop} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 0,
              "step" => %{"type" => "function_call", "id" => "fc_resumed", "name" => "weather"}
            }
          },
          model,
          s_delta
        )

      assert [
               %StreamChunk{
                 type: :tool_call,
                 name: "weather",
                 arguments: %{"city" => "SF"},
                 metadata: %{id: "fc_resumed"}
               }
             ] = fc_chunks

      assert s_fc_stop.completed_steps[0]["name"] == "weather"

      {nil_fc_chunks, s_nil_fc} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{"event_type" => "step.stop", "index" => 1}
          },
          model,
          s_delta
          |> put_in([:steps, 1], %{"type" => "function_call", "_arg_chunks" => [~s({"a":1})]})
        )

      assert nil_fc_chunks == []
      refute Map.has_key?(s_nil_fc.completed_steps, 1)
    end

    test "decodes mid-step resume function_call with last_event_id and complete stop args" do
      {:ok, model} = ReqLLM.model(@model_id)

      init_resumed =
        Google.init_stream_state(model,
          google_api: :interactions,
          last_event_id: "evt_mid"
        )

      {_, mid_fc_1} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "arguments_delta", "arguments" => ~s("NYC"})}
            }
          },
          model,
          init_resumed
        )

      {fc_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 0,
              "step" => %{
                "type" => "function_call",
                "id" => "fc_mid",
                "name" => "get_weather",
                "arguments" => %{"city" => "NYC"}
              }
            }
          },
          model,
          mid_fc_1
        )

      assert [%StreamChunk{type: :tool_call, name: "get_weather", arguments: %{"city" => "NYC"}}] =
               fc_chunks
    end

    test "replaces partial resumed model_output with full completed snapshot" do
      {:ok, model} = ReqLLM.model(@model_id)

      init_resumed =
        Google.init_stream_state(model,
          google_api: :interactions,
          last_event_id: "evt_mid"
        )

      {_, mid_text_1} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 0,
              "step" => %{"type" => "model_output"}
            }
          },
          model,
          init_resumed
        )

      {_, mid_text_2} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "text", "text" => "partial."}
            }
          },
          model,
          mid_text_1
        )

      {_, mid_text_3} =
        Google.decode_stream_event(
          %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
          model,
          mid_text_2
        )

      {mid_done_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "interaction.completed",
            data: %{
              "event_type" => "interaction.completed",
              "interaction" => %{
                "id" => "int_mid_single",
                "status" => "completed",
                "steps" => [
                  %{
                    "type" => "model_output",
                    "content" => [%{"type" => "text", "text" => "Full answer, not partial."}]
                  }
                ]
              }
            }
          },
          model,
          mid_text_3
        )

      assert List.last(mid_done_chunks).metadata[:google_interactions_steps] == [
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "text", "text" => "Full answer, not partial."}]
               }
             ]
    end

    test "merges deltas when step.start arrives out of order after step.delta" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, s_ooo1} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 2,
              "delta" => %{"type" => "text", "text" => "World"}
            }
          },
          model,
          init
        )

      {_, s_ooo2} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 2,
              "step" => %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "Hello "}]
              }
            }
          },
          model,
          s_ooo1
        )

      {_, s_ooo3} =
        Google.decode_stream_event(
          %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 2}},
          model,
          s_ooo2
        )

      assert s_ooo3.completed_steps[2] == %{
               "type" => "model_output",
               "content" => [%{"type" => "text", "text" => "Hello World"}]
             }
    end

    test "coalesces consecutive thought_summary deltas and avoids stop duplication" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, s_t1} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
          },
          model,
          init
        )

      {_, s_t2} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{
                "type" => "thought_summary",
                "content" => %{"type" => "text", "text" => "Plan A "}
              }
            }
          },
          model,
          s_t1
        )

      {_, s_t3} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{
                "type" => "thought_summary",
                "content" => %{"type" => "text", "text" => "Plan B"}
              }
            }
          },
          model,
          s_t2
        )

      {_, s_t4} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{"event_type" => "step.stop", "index" => 0}
          },
          model,
          s_t3
        )

      assert s_t4.completed_steps[0]["summary"] == [
               %{"type" => "text", "text" => "Plan A Plan B"}
             ]

      {[], td1} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
          },
          model,
          init
        )

      {_, td2} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{
                "type" => "thought_summary",
                "content" => %{"type" => "text", "text" => "Echoed"}
              }
            }
          },
          model,
          td1
        )

      {_, td3} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 0,
              "step" => %{
                "type" => "thought",
                "summary" => [%{"type" => "text", "text" => "Echoed"}]
              }
            }
          },
          model,
          td2
        )

      assert td3.completed_steps[0]["summary"] == [%{"type" => "text", "text" => "Echoed"}]
    end

    test "sets failed terminal error metadata and preserves raw in_progress on flush" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {failed_done_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "interaction.completed",
            data: %{
              "event_type" => "interaction.completed",
              "interaction" => %{
                "id" => "int_fail_done",
                "status" => "failed",
                "errors" => [%{"code" => "internal", "message" => "Agent failed"}]
              }
            }
          },
          model,
          init
        )

      failed_meta = List.last(failed_done_chunks).metadata
      assert failed_meta[:finish_reason] == :error
      assert %ResponseError{reason: "Agent failed"} = failed_meta[:error]

      assert failed_meta[:provider_meta]["errors"] == [
               %{"code" => "internal", "message" => "Agent failed"}
             ]

      {_, s_status} =
        Google.decode_stream_event(
          %{
            event: "interaction.status_update",
            data: %{
              "event_type" => "interaction.status_update",
              "interaction_id" => "int_trunc",
              "status" => "in_progress"
            }
          },
          model,
          init
        )

      {flushed_trunc, _} = Google.flush_stream_state(model, s_status)
      assert List.last(flushed_trunc).metadata[:finish_reason_raw] == "in_progress"
    end

    test "preserves step.stop-carried thought summary, signature, and model_output content" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model)

      {[], s1} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
          },
          model,
          init
        )

      {t_stop_chunks, s2} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 0,
              "step" => %{
                "type" => "thought",
                "summary" => [%{"type" => "text", "text" => "Stop-only thought"}],
                "signature" => "sig_stop_thought"
              }
            }
          },
          model,
          s1
        )

      assert [
               %StreamChunk{
                 type: :thinking,
                 text: "Stop-only thought",
                 metadata: %{signature: "sig_stop_thought"}
               }
             ] = t_stop_chunks

      assert s2.completed_steps[0] == %{
               "type" => "thought",
               "signature" => "sig_stop_thought",
               "summary" => [%{"type" => "text", "text" => "Stop-only thought"}]
             }

      {[], s3} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 1,
              "step" => %{"type" => "model_output"}
            }
          },
          model,
          s2
        )

      {m_stop_chunks, s4} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 1,
              "step" => %{
                "type" => "model_output",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => "Stop-only answer",
                    "annotations" => [%{"id" => "ann_stop"}]
                  }
                ]
              }
            }
          },
          model,
          s3
        )

      assert [%StreamChunk{type: :content_part}] = m_stop_chunks
      assert s4.rev_annotations == [%{"id" => "ann_stop"}]

      assert s4.completed_steps[1] == %{
               "type" => "model_output",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Stop-only answer",
                   "annotations" => [%{"id" => "ann_stop"}]
                 }
               ]
             }
    end

    test "skips JSON object decoding on incomplete or flushed schema-only streams" do
      {:ok, model} = ReqLLM.model(@model_id)

      schema_state =
        Google.init_stream_state(model,
          google_api: :interactions,
          response_format: %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          }
        )

      assert schema_state.expect_json_object? == true

      {_, partial_obj_state} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 0,
              "step" => %{"type" => "model_output"}
            }
          },
          model,
          schema_state
        )

      {_, partial_obj_state} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "text", "text" => ~s({"ok":)}
            }
          },
          model,
          partial_obj_state
        )

      {_, partial_obj_state} =
        Google.decode_stream_event(
          %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
          model,
          partial_obj_state
        )

      {budget_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "interaction.completed",
            data: %{
              "event_type" => "interaction.completed",
              "interaction" => %{"id" => "int_trunc_obj", "status" => "budget_exceeded"}
            }
          },
          model,
          partial_obj_state
        )

      refute Map.has_key?(List.last(budget_chunks).metadata, :object)

      {flush_chunks, _} = Google.flush_stream_state(model, partial_obj_state)
      refute Map.has_key?(List.last(flush_chunks).metadata, :object)
    end

    test "tracks multi-step built-in tool usage across step.stop and flush_stream_state" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, s1} =
        Google.decode_stream_event(
          %{
            "event" => "step.stop",
            "data" =>
              Jason.encode!(%{
                "event_type" => "step.stop",
                "index" => 0,
                "step" => %{
                  "type" => "google_search_call",
                  "id" => "gs_1",
                  "arguments" => %{"queries" => ["elixir"]}
                }
              })
          },
          model,
          init
        )

      {_, s2} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 1,
              "step" => %{
                "type" => "code_execution_call",
                "id" => "ce_1",
                "language" => "PYTHON",
                "code" => "x = "
              }
            }
          },
          model,
          s1
        )

      {_, s3} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 1,
              "delta" => %{
                "event_type" => "step.delta",
                "type" => "code_execution_call",
                "language" => "PYTHON",
                "code" => "1"
              }
            }
          },
          model,
          s2
        )

      {_, s4} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 2,
              "step" => %{
                "type" => "google_search_call",
                "id" => "gs_2",
                "arguments" => %{"queries" => ["phoenix", "otp"]}
              }
            }
          },
          model,
          s3
        )

      {flushed, _} = Google.flush_stream_state(model, s4)
      flushed_meta = List.last(flushed).metadata

      assert flushed_meta[:usage].tool_usage == %{
               web_search: %{count: 3, unit: :query},
               code_execution: %{count: 1, unit: :call}
             }

      assert length(flushed_meta[:provider_meta]["builtin_tools"]) == 3

      ce_step = Enum.find(flushed_meta[:google_interactions_steps], &(&1["id"] == "ce_1"))
      assert ce_step["language"] == "PYTHON"
      assert ce_step["code"] == "x = 1"
      refute Map.has_key?(ce_step, "event_type")
    end

    test "ignores ping and [DONE] events and decodes binary error SSE wrappers" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      assert {[], ^init} = Google.decode_stream_event(%{event: "ping", data: nil}, model, init)
      assert {[], ^init} = Google.decode_stream_event(%{"data" => "[DONE]"}, model, init)

      {err_chunks, _} =
        Google.decode_stream_event(
          %{"event" => "error", "data" => "Upstream proxy unavailable"},
          model,
          init
        )

      assert List.last(err_chunks).metadata[:error].reason == "Upstream proxy unavailable"
    end

    test "handles SSE error events with non-map error fields without crashing" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {string_err_chunks, string_err_state} =
        Google.decode_stream_event(
          %{
            event: "error",
            data: %{"event_type" => "error", "error" => "upstream timeout"}
          },
          model,
          init
        )

      assert string_err_state.terminated? == true

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{
                   finish_reason: :error,
                   error: %ResponseError{reason: "upstream timeout"}
                 }
               }
             ] = string_err_chunks

      {list_err_chunks, list_err_state} =
        Google.decode_stream_event(
          %{
            event: "error",
            data: %{"event_type" => "error", "error" => ["unexpected", "list"]}
          },
          model,
          init
        )

      assert list_err_state.terminated? == true

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{
                   finish_reason: :error,
                   error: %ResponseError{
                     reason: "Google Interactions stream error",
                     response_body: %{"error" => ["unexpected", "list"]}
                   }
                 }
               }
             ] = list_err_chunks

      {errors_list_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "error",
            data: %{
              "event_type" => "error",
              "errors" => [%{"code" => "internal", "message" => "Agent failed"}]
            }
          },
          model,
          init
        )

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{
                   finish_reason: :error,
                   error: %ResponseError{reason: "Agent failed"},
                   provider_meta: %{
                     "errors" => [%{"code" => "internal", "message" => "Agent failed"}]
                   }
                 }
               }
             ] = errors_list_chunks
    end

    test "attaches flat thought_summary and stream signatures to steps" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, s1} =
        Google.decode_stream_event(
          %{
            event: "interaction.created",
            data: %{
              "event_type" => "interaction.created",
              "interaction" => %{"id" => "int_sig", "status" => "in_progress"}
            }
          },
          model,
          init
        )

      {[], s2} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
          },
          model,
          s1
        )

      {flat_chunks, s3} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "thought_summary", "text" => "Flat thinking"}
            }
          },
          model,
          s2
        )

      assert [%StreamChunk{type: :thinking, text: "Flat thinking"}] = flat_chunks

      {[], s4} =
        Google.decode_stream_event(
          %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 0}},
          model,
          s3
        )

      {[], s5} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 1,
              "step" => %{"type" => "function_call", "name" => "lookup"}
            }
          },
          model,
          s4
        )

      {[], s6} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 1,
              "delta" => %{"type" => "thought_signature", "signature" => "sig_fc_stream"}
            }
          },
          model,
          s5
        )

      {fc_chunks, s7} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 1,
              "step" => %{
                "type" => "function_call",
                "name" => "lookup",
                "arguments" => %{"q" => "ok"}
              }
            }
          },
          model,
          s6
        )

      assert [
               %StreamChunk{
                 type: :tool_call,
                 metadata: %{id: "call_int_sig_1", signature: "sig_fc_stream"}
               }
             ] = fc_chunks

      assert s7.completed_steps[1]["id"] == "call_int_sig_1"
      assert s7.completed_steps[1]["signature"] == "sig_fc_stream"

      {[], s8} =
        Google.decode_stream_event(
          %{
            event: "step.start",
            data: %{
              "event_type" => "step.start",
              "index" => 2,
              "step" => %{"type" => "model_output"}
            }
          },
          model,
          s7
        )

      {_, s9} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 2,
              "delta" => %{"type" => "text", "text" => "Done"}
            }
          },
          model,
          s8
        )

      {[], s10} =
        Google.decode_stream_event(
          %{
            event: "step.delta",
            data: %{
              "event_type" => "step.delta",
              "index" => 2,
              "delta" => %{"type" => "thought_signature", "signature" => "sig_mo_stream"}
            }
          },
          model,
          s9
        )

      {[], s11} =
        Google.decode_stream_event(
          %{event: "step.stop", data: %{"event_type" => "step.stop", "index" => 2}},
          model,
          s10
        )

      assert s11.completed_steps[2]["signature"] == "sig_mo_stream"

      {completed_chunks, s12} =
        Google.decode_stream_event(
          %{
            event: "interaction.completed",
            data: %{
              "event_type" => "interaction.completed",
              "interaction" => %{"id" => "int_sig"}
            }
          },
          model,
          s11
        )

      assert List.last(completed_chunks).metadata[:finish_reason] == :tool_calls
      assert List.last(completed_chunks).metadata[:finish_reason_raw] == "completed"

      {dup_chunks, ^s12} =
        Google.decode_stream_event(
          %{
            event: "interaction.status_update",
            data: %{"event_type" => "interaction.status_update", "status" => "completed"}
          },
          model,
          s12
        )

      assert dup_chunks == []
    end

    test "maps flushed truncated status to :incomplete and status_update cancelled" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, trunc_state} =
        Google.decode_stream_event(
          %{
            event: "interaction.created",
            data: %{
              "event_type" => "interaction.created",
              "interaction" => %{"id" => "int_cut", "status" => "in_progress"}
            }
          },
          model,
          init
        )

      {flushed, _} = Google.flush_stream_state(model, trunc_state)
      assert List.last(flushed).metadata[:finish_reason] == :incomplete
      assert List.last(flushed).metadata[:finish_reason_raw] == "in_progress"

      {status_chunks, _} =
        Google.decode_stream_event(
          %{
            event: "interaction.status_update",
            data: %{
              "event_type" => "interaction.status_update",
              "interaction" => %{"id" => "int_nested", "status" => "cancelled"}
            }
          },
          model,
          init
        )

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{response_id: "int_nested", finish_reason: :cancelled}
               }
             ] = status_chunks
    end

    test "preserves accumulated usage and tool_usage across interaction.status_update events" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      {_, after_stop} =
        Google.decode_stream_event(
          %{
            event: "step.stop",
            data: %{
              "event_type" => "step.stop",
              "index" => 0,
              "step" => %{
                "type" => "google_search_call",
                "id" => "gs_1",
                "arguments" => %{"queries" => ["elixir"]}
              },
              "usage" => %{
                "total_input_tokens" => 120,
                "total_output_tokens" => 30
              }
            }
          },
          model,
          init
        )

      {status_no_usage_chunks, after_status_no_usage} =
        Google.decode_stream_event(
          %{
            event: "interaction.status_update",
            data: %{
              "event_type" => "interaction.status_update",
              "interaction_id" => "int_su",
              "status" => "in_progress",
              "continuation_token" => "ct_1"
            }
          },
          model,
          after_stop
        )

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{
                   response_id: "int_su",
                   usage: %{
                     input_tokens: 120,
                     output_tokens: 30,
                     total_tokens: 150,
                     tool_usage: %{web_search: %{count: 1, unit: :query}}
                   }
                 }
               }
             ] = status_no_usage_chunks

      {status_empty_usage_chunks, after_status_empty_usage} =
        Google.decode_stream_event(
          %{
            event: "interaction.status_update",
            data: %{
              "event_type" => "interaction.status_update",
              "interaction_id" => "int_su",
              "status" => "in_progress",
              "usage" => %{}
            }
          },
          model,
          after_status_no_usage
        )

      assert [
               %StreamChunk{
                 type: :meta,
                 metadata: %{
                   usage: %{
                     input_tokens: 120,
                     output_tokens: 30,
                     total_tokens: 150,
                     tool_usage: %{web_search: %{count: 1, unit: :query}}
                   }
                 }
               }
             ] = status_empty_usage_chunks

      assert after_status_empty_usage.usage == %{
               input_tokens: 120,
               output_tokens: 30,
               total_tokens: 150,
               cached_tokens: 0,
               reasoning_tokens: 0,
               tool_use_input_tokens: 0,
               tool_usage: %{web_search: %{count: 1, unit: :query}}
             }
    end

    test "replaces empty step.start text with model_output stop content and annotations" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      empty_start_events = [
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [%{"type" => "text", "text" => ""}]
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "Stop text",
                  "annotations" => [%{"id" => "ann_empty_start"}]
                }
              ]
            }
          }
        }
      ]

      {empty_start_chunks, empty_start_state} =
        Enum.reduce(empty_start_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert [%StreamChunk{type: :content_part}] = empty_start_chunks
      assert empty_start_state.rev_annotations == [%{"id" => "ann_empty_start"}]

      assert empty_start_state.completed_steps[0] == %{
               "type" => "model_output",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Stop text",
                   "annotations" => [%{"id" => "ann_empty_start"}]
                 }
               ]
             }
    end

    test "merges streamed text deltas with model_output stop annotations and media" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      delta_plus_stop_events = [
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{"type" => "model_output"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "text", "text" => "Streamed "}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "text", "text" => "answer"}
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "Streamed answer",
                  "annotations" => [%{"id" => "ann_stop"}]
                },
                %{
                  "type" => "image",
                  "uri" => "https://example.com/chart.png",
                  "mime_type" => "image/png"
                }
              ]
            }
          }
        },
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_mo_stop", "status" => "completed"}
          }
        }
      ]

      {mo_chunks, mo_state} =
        Enum.reduce(delta_plus_stop_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert mo_state.completed_steps[0] == %{
               "type" => "model_output",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Streamed answer",
                   "annotations" => [%{"id" => "ann_stop"}]
                 },
                 %{
                   "type" => "image",
                   "uri" => "https://example.com/chart.png",
                   "mime_type" => "image/png"
                 }
               ]
             }

      {:ok, mo_built} =
        ResponseBuilder.build_response(
          mo_chunks,
          List.last(mo_chunks).metadata,
          context: Context.new([Context.user("Hi")]),
          model: model
        )

      assert ReqLLM.Response.text(mo_built) == "Streamed answer"
      assert ReqLLM.Response.annotations(mo_built) == [%{"id" => "ann_stop"}]

      assert Enum.any?(
               mo_built.message.content,
               &match?(%ContentPart{type: :image_url, url: "https://example.com/chart.png"}, &1)
             )
    end

    test "prefers step.stop type over earlier thought_signature delta on call and output" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      sig_first_fc_events = [
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_signature", "signature" => "sig_fc"}
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "function_call",
              "id" => "fc_no_start",
              "name" => "lookup",
              "arguments" => %{"q" => "elixir"}
            }
          }
        }
      ]

      {fc_chunks, fc_state} =
        Enum.reduce(sig_first_fc_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert [
               %StreamChunk{
                 type: :tool_call,
                 name: "lookup",
                 arguments: %{"q" => "elixir"},
                 metadata: %{id: "fc_no_start", index: 0, signature: "sig_fc"}
               }
             ] = fc_chunks

      assert fc_state.completed_steps[0] == %{
               "type" => "function_call",
               "id" => "fc_no_start",
               "name" => "lookup",
               "arguments" => %{"q" => "elixir"},
               "signature" => "sig_fc"
             }

      sig_first_mo_events = [
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_signature", "signature" => "sig_mo"}
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [%{"type" => "text", "text" => "After sig"}]
            }
          }
        }
      ]

      {sig_mo_chunks, sig_mo_state} =
        Enum.reduce(sig_first_mo_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert [%StreamChunk{type: :content, text: "After sig"}] = sig_mo_chunks

      assert sig_mo_state.completed_steps[0] == %{
               "type" => "model_output",
               "content" => [%{"type" => "text", "text" => "After sig"}],
               "signature" => "sig_mo"
             }
    end

    test "recovers thought summary from step.stop after empty delta or empty start" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      empty_thought_delta_events = [
        %{
          event: "step.start",
          data: %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}}
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_summary", "text" => ""}
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "thought",
              "summary" => [%{"type" => "text", "text" => "Stop summary after empty delta"}]
            }
          }
        }
      ]

      {etd_chunks, _} =
        Enum.reduce(empty_thought_delta_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert [%StreamChunk{type: :thinking, text: "Stop summary after empty delta"}] = etd_chunks

      empty_thought_start_events = [
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{
              "type" => "thought",
              "summary" => [%{"type" => "text", "text" => ""}]
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "thought",
              "summary" => [%{"type" => "text", "text" => "Stop summary after empty start"}]
            }
          }
        }
      ]

      {ets_chunks, _} =
        Enum.reduce(empty_thought_start_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert [%StreamChunk{type: :thinking, text: "Stop summary after empty start"}] = ets_chunks
    end

    test "preserves grounding tool_usage when later step usage omits grounding metadata" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      grounding_stream_events = [
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "google_search_call",
              "id" => "gs_1",
              "arguments" => %{"queries" => ["elixir"]}
            },
            "usage" => %{
              "total_input_tokens" => 50,
              "total_output_tokens" => 10,
              "grounding_tool_count" => [%{"tool" => "google_search", "count" => 3}]
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 1,
            "step" => %{"type" => "code_execution_call", "id" => "ce_1"}
          }
        },
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_grounding_keep", "status" => "completed"}
          }
        }
      ]

      {g_chunks, _} =
        Enum.reduce(grounding_stream_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert List.last(g_chunks).metadata[:usage].tool_usage == %{
               web_search: %{count: 3, unit: :query},
               code_execution: %{count: 1, unit: :call}
             }

      multi_search_stream_events = [
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "google_search_call",
              "id" => "gs_1",
              "arguments" => %{"queries" => ["q1"]}
            },
            "usage" => %{
              "total_input_tokens" => 50,
              "total_output_tokens" => 10
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 1,
            "step" => %{
              "type" => "google_search_call",
              "id" => "gs_2",
              "arguments" => %{"queries" => ["q2"]}
            }
          }
        },
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_multi_search", "status" => "completed"}
          }
        }
      ]

      {ms_chunks, _} =
        Enum.reduce(multi_search_stream_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert List.last(ms_chunks).metadata[:usage].tool_usage == %{
               web_search: %{count: 2, unit: :query}
             }
    end

    test "deduplicates delta media and preserves step.stop-only text annotations" do
      {:ok, model} = ReqLLM.model(@model_id)
      init = Google.init_stream_state(model, google_api: :interactions)

      dedup_stop_events = [
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{"type" => "model_output"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "text", "text" => "Lead", "annotations" => [%{"id" => "a1"}]}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{
              "type" => "image",
              "data" => Base.encode64(<<4, 5, 6>>),
              "mime_type" => "image/png"
            }
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [
                %{
                  "type" => "text",
                  "text" => "Lead",
                  "annotations" => [%{"id" => "a1"}, %{"id" => "a2"}]
                },
                %{
                  "type" => "image",
                  "data" => Base.encode64(<<4, 5, 6>>),
                  "mime_type" => "image/png"
                }
              ]
            }
          }
        },
        %{
          event: "interaction.completed",
          data: %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "int_dedup_stop", "status" => "completed"}
          }
        }
      ]

      {dedup_chunks, _} =
        Enum.reduce(dedup_stop_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert Enum.count(dedup_chunks, &(&1.type == :content_part)) == 1

      {:ok, dedup_built} =
        ResponseBuilder.build_response(
          dedup_chunks,
          List.last(dedup_chunks).metadata,
          context: Context.new([Context.user("Hi")]),
          model: model
        )

      assert ReqLLM.Response.annotations(dedup_built) == [%{"id" => "a1"}, %{"id" => "a2"}]

      ann_only_stop_events = [
        %{
          event: "step.start",
          data: %{
            "event_type" => "step.start",
            "index" => 0,
            "step" => %{"type" => "model_output"}
          }
        },
        %{
          event: "step.delta",
          data: %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "text", "text" => "Streamed"}
          }
        },
        %{
          event: "step.stop",
          data: %{
            "event_type" => "step.stop",
            "index" => 0,
            "step" => %{
              "type" => "model_output",
              "content" => [
                %{"type" => "text", "text" => "", "annotations" => [%{"id" => "ann_only"}]}
              ]
            }
          }
        }
      ]

      {ann_only_chunks, ann_only_state} =
        Enum.reduce(ann_only_stop_events, {[], init}, fn ev, {acc, st} ->
          {new_chunks, next_st} = Google.decode_stream_event(ev, model, st)
          {acc ++ new_chunks, next_st}
        end)

      assert ann_only_state.rev_annotations == [%{"id" => "ann_only"}]

      assert Enum.any?(
               ann_only_chunks,
               &match?(
                 %StreamChunk{type: :meta, metadata: %{annotations: [%{"id" => "ann_only"}]}},
                 &1
               )
             )

      assert ann_only_state.completed_steps[0] == %{
               "type" => "model_output",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "Streamed",
                   "annotations" => [%{"id" => "ann_only"}]
                 }
               ]
             }
    end
  end
end
