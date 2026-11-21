defmodule ReqLLM.Providers.Google.InteractionsAPI.ResponseDecodingTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Google.InteractionsAPIHelpers, only: [inline_json_plug: 1]

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.InteractionsAPI.Decoder
  alias ReqLLM.ToolCall

  @model_id "google:gemini-4-hydrogen"
  @api_key "test-google-key"

  defp trace_flash_lite_payload do
    %{
      "id" => "v1_Chd5bXRKYXZ6YkxZZXQxTWtQOWFQcnlBMBIXeW10SmF2emJMWWV0MU1rUDlhUHJ5QTA",
      "status" => "completed",
      "usage" => %{
        "total_tokens" => 859,
        "total_input_tokens" => 224,
        "input_tokens_by_modality" => [%{"modality" => "text", "tokens" => 224}],
        "total_cached_tokens" => 0,
        "total_output_tokens" => 73,
        "total_tool_use_tokens" => 562,
        "tool_use_tokens_by_modality" => [%{"modality" => "text", "tokens" => 562}],
        "total_thought_tokens" => 0
      },
      "service_tier" => "standard",
      "steps" => [
        %{
          "id" => "TsWVzoeN",
          "signature" => "sig_fs_call_1",
          "type" => "file_search_call"
        },
        %{
          "call_id" => "TsWVzoeN",
          "signature" => "sig_fs_res_1",
          "type" => "file_search_result"
        },
        %{
          "signature" => "sig_thought_only_1",
          "type" => "thought"
        },
        %{
          "content" => [
            %{
              "text" => ~s({"summary":"No document found.","document_type":"unknown"}),
              "type" => "text"
            }
          ],
          "type" => "model_output"
        }
      ],
      "object" => "interaction",
      "model" => "gemini-3.1-flash-lite"
    }
  end

  defp trace_citations_step_order_payload do
    %{
      "id" => "v1_ChdjSUJKYXFhUExxaXgxTWtQc3AybndBbxIXY0lCSmFxYVBMcWl4MU1rUHNwMm53QW8",
      "status" => "completed",
      "usage" => %{
        "total_tokens" => 897,
        "total_input_tokens" => 224,
        "total_cached_tokens" => 0,
        "total_output_tokens" => 192,
        "total_tool_use_tokens" => 396,
        "total_thought_tokens" => 85
      },
      "service_tier" => "standard",
      "steps" => [
        %{
          "signature" => "sig_thought_before_output",
          "type" => "thought"
        },
        %{
          "content" => [
            %{
              "text" => "Valley Forge Capital fund presentation.",
              "annotations" => [
                %{
                  "start_index" => 0,
                  "end_index" => 20,
                  "document_uri" => "fileSearchStores/clientpitchdeckupload179-lgbsvzc0i9x3",
                  "file_name" => "psp24cgqwlel",
                  "page_number" => 17,
                  "type" => "file_citation"
                }
              ],
              "type" => "text"
            }
          ],
          "type" => "model_output"
        },
        %{
          "id" => "7tr8zjdq",
          "type" => "file_search_call"
        },
        %{
          "call_id" => "7tr8zjdq",
          "type" => "file_search_result"
        }
      ],
      "object" => "interaction",
      "model" => "gemini-2.5-flash"
    }
  end

  describe "buffered HTTP generation and response decoding" do
    test "executes buffered generate_text and generate_object through Req.Test stub plug" do
      parent = self()

      chat_plug =
        inline_json_plug(fn %{conn: conn, body: req_body} ->
          send(parent, {:chat_request, conn.request_path, conn.req_headers, req_body})

          {200,
           %{
             "id" => "int_chat_1",
             "model" => "gemini-4-hydrogen",
             "status" => "completed",
             "service_tier" => "priority",
             "steps" => [
               %{"type" => "thought", "summary" => [%{"type" => "text", "text" => "Thinking"}]},
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "text", "text" => "Hello from Interactions"}]
               }
             ],
             "usage" => %{
               "total_input_tokens" => 10,
               "total_output_tokens" => 5,
               "total_thought_tokens" => 3,
               "total_cached_tokens" => 2,
               "total_tool_use_tokens" => 4,
               "total_tokens" => 22
             }
           }}
        end)

      {:ok, resp} =
        ReqLLM.generate_text(@model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions,
          req_http_options: [plug: chat_plug]
        )

      assert_receive {:chat_request, "/v1/interactions", headers, req_body}
      assert {"api-revision", "2026-05-20"} in headers
      assert req_body["model"] == "gemini-4-hydrogen"
      assert ReqLLM.Response.text(resp) == "Hello from Interactions"
      assert ReqLLM.Response.thinking(resp) == "Thinking"
      assert resp.finish_reason == :stop
      assert resp.provider_meta["interaction_id"] == "int_chat_1"
      assert resp.provider_meta["service_tier"] == "priority"
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 8
      assert resp.usage.reasoning_tokens == 3
      assert resp.usage.cached_tokens == 2
      assert resp.usage.tool_use_input_tokens == 4
      assert resp.usage.total_tokens == 22

      schema = [answer: [type: :integer, required: true]]

      obj_plug =
        inline_json_plug(fn %{body: req_body} ->
          send(parent, {:obj_request, req_body})

          {200,
           %{
             "id" => "int_obj_1",
             "model" => "gemini-4-hydrogen",
             "status" => "completed",
             "steps" => [
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "text", "text" => ~s({"answer":42})}]
               }
             ],
             "usage" => %{
               "total_input_tokens" => 5,
               "total_output_tokens" => 4,
               "total_tokens" => 9
             }
           }}
        end)

      {:ok, obj_resp} =
        ReqLLM.generate_object(@model_id, "Answer?", schema,
          api_key: @api_key,
          google_api: :interactions,
          req_http_options: [plug: obj_plug]
        )

      assert_receive {:obj_request, obj_req_body}
      assert obj_req_body["response_format"]["mime_type"] == "application/json"
      assert obj_resp.object == %{"answer" => 42}
    end

    test "plain :chat keeps resp.object nil for JSON text" do
      for payload_text <- [~s({"ok":true}), ~s([1,2,3])] do
        chat_plug = fn conn ->
          Req.Test.json(%{conn | status: 200}, %{
            "id" => "int_chat_json",
            "model" => "gemini-4-hydrogen",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => payload_text}]
              }
            ]
          })
        end

        {:ok, chat_resp} =
          ReqLLM.generate_text(@model_id, "Reply",
            api_key: @api_key,
            google_api: :interactions,
            req_http_options: [plug: chat_plug]
          )

        assert ReqLLM.Response.text(chat_resp) == payload_text
        assert chat_resp.object == nil
      end
    end

    test "decodes attached Google HTTP responses symmetrically and resolves managed agent model" do
      {:ok, agent_model} = ReqLLM.model(@model_id)

      {:ok, agent_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_agent_1",
            "agent" => "deep-research-pro-preview-12-2025",
            "status" => "completed",
            "steps" => [
              %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "Report"}]}
            ]
          },
          agent_model,
          Context.new([Context.user("Research")])
        )

      assert agent_resp.model == "deep-research-pro-preview-12-2025"
      assert agent_resp.provider_meta["agent"] == "deep-research-pro-preview-12-2025"

      attach_req =
        Req.new(url: "/interactions", method: :post)
        |> Google.attach(agent_model,
          api_key: @api_key,
          provider_options: [google_api: :interactions]
        )

      raw_http_resp =
        Req.Response.new(
          status: 200,
          body: %{
            "id" => "int_attached",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "Symmetry"}]
              }
            ]
          }
        )

      {_req, %Req.Response{body: %ReqLLM.Response{} = decoded_sym}} =
        Google.decode_response({attach_req, raw_http_resp})

      assert ReqLLM.Response.text(decoded_sym) == "Symmetry"
    end

    test "handles trace fixtures with signature-only thought, non-trailing model_output, annotations, and provider_blocks" do
      {:ok, model_lite} = ReqLLM.model("google:gemini-3.1-flash-lite")

      {:ok, lite_resp} =
        InteractionsAPI.decode_interaction_body(
          trace_flash_lite_payload(),
          model_lite,
          Context.new([Context.user("Analyze")])
        )

      assert ReqLLM.Response.text(lite_resp) ==
               ~s({"summary":"No document found.","document_type":"unknown"})

      assert ReqLLM.Response.thinking(lite_resp) == ""

      assert [
               %Message.ReasoningDetails{
                 signature: "sig_thought_only_1",
                 encrypted?: true,
                 format: "google-interactions-v1",
                 provider_data: %{"type" => "thought"}
               }
             ] = lite_resp.message.reasoning_details

      assert Enum.count(lite_resp.message.content, &(&1.type == :provider_block)) == 2
      assert length(lite_resp.provider_meta["builtin_tools"]) == 2
      assert is_list(InteractionsAPI.verified_interactions_steps(lite_resp.message))

      {:ok, model_25} = ReqLLM.model("google:gemini-2.5-flash")

      {:ok, cite_resp} =
        InteractionsAPI.decode_interaction_body(
          trace_citations_step_order_payload(),
          model_25,
          Context.new([Context.user("Analyze")])
        )

      assert ReqLLM.Response.text(cite_resp) == "Valley Forge Capital fund presentation."

      assert [%{"type" => "file_citation", "file_name" => "psp24cgqwlel"}] =
               ReqLLM.Response.annotations(cite_resp)

      {:ok, gs_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_gs_1",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "google_search_call",
                "id" => "gs_1",
                "arguments" => %{"queries" => ["elixir"]}
              },
              %{
                "type" => "google_search_result",
                "call_id" => "gs_1",
                "result" => [%{"url" => "https://elixir-lang.org"}]
              },
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "Elixir info."}]
              }
            ],
            "usage" => %{
              "total_input_tokens" => 5,
              "total_output_tokens" => 3,
              "total_tool_use_tokens" => 10
            }
          },
          model_lite,
          Context.new([Context.user("Elixir")])
        )

      assert %{web_search: %{count: 1, unit: unit}} = gs_resp.usage.tool_usage
      assert unit in [:call, :query]
    end
  end

  describe "status mapping, multimodal decoding, and step slicing" do
    test "maps interaction statuses and distinguishes sync vs background failures" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Run tool")])

      {:ok, tc_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_tc",
            "status" => "requires_action",
            "steps" => [
              %{
                "type" => "function_call",
                "id" => "fc_1",
                "name" => "search",
                "arguments" => %{"q" => "hi"}
              }
            ]
          },
          model,
          context
        )

      assert tc_resp.finish_reason == :tool_calls
      assert [%ToolCall{id: "fc_1"} = tc] = ReqLLM.Response.tool_calls(tc_resp)
      assert ToolCall.name(tc) == "search"
      assert ToolCall.args_map(tc) == %{"q" => "hi"}

      {:ok, cont_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_cont",
            "status" => "requires_continuation",
            "continuation_token" => "tok_next",
            "steps" => [
              %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "Partial"}]}
            ]
          },
          model,
          context
        )

      assert cont_resp.finish_reason == :incomplete
      assert cont_resp.provider_meta["continuation_token"] == "tok_next"

      for {raw_status, expected} <- [
            {"incomplete", :incomplete},
            {"budget_exceeded", :length},
            {"cancelled", :cancelled}
          ] do
        {:ok, status_resp} =
          InteractionsAPI.decode_interaction_body(
            %{"id" => "int_#{raw_status}", "status" => raw_status, "steps" => []},
            model,
            context
          )

        assert status_resp.finish_reason == expected
      end

      {:ok, sync_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions
        )

      failed_http = %Req.Response{
        status: 200,
        body: %{
          "id" => "int_fail",
          "status" => "failed",
          "errors" => [%{"code" => "internal", "message" => "Execution failed"}]
        }
      }

      {_, %ResponseError{reason: "Execution failed"}} =
        Google.decode_response({sync_req, failed_http})

      {:ok, bg_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions,
          background: true
        )

      {_,
       %Req.Response{
         body: %ReqLLM.Response{
           finish_reason: :error,
           error: %ResponseError{reason: "Execution failed"}
         }
       }} =
        Google.decode_response({bg_req, failed_http})

      {_, %ResponseError{status: 200}} =
        Google.decode_response({sync_req, %Req.Response{status: 200, body: "<html>bad</html>"}})
    end

    test "verifies and replays multimodal image responses and drops verified steps when tampered" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Draw")])
      raw_jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10>>

      {:ok, multimodal_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_mm",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [
                  %{"type" => "text", "text" => "Here is the chart"},
                  %{
                    "type" => "image",
                    "data" => Base.encode64(raw_jpeg),
                    "mime_type" => "image/jpeg"
                  }
                ]
              }
            ]
          },
          model,
          context
        )

      assert [%{"type" => "model_output"}] =
               InteractionsAPI.verified_interactions_steps(multimodal_resp.message)

      replayed_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Draw"), multimodal_resp.message, Context.user("Explain")]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{"type" => "model_output", "content" => [_, %{"type" => "image"}]},
               %{"type" => "user_input"}
             ] = replayed_body["input"]

      tampered_msg = %{multimodal_resp.message | content: [ContentPart.text("Tampered")]}
      assert InteractionsAPI.verified_interactions_steps(tampered_msg) == nil
    end

    test "preserves invalid base64 images as provider_block and decodes url-safe unpadded base64" do
      {:ok, model} = ReqLLM.model(@model_id)
      raw_bytes = <<1, 2, 3, 255>>
      url_safe_unpadded = Base.url_encode64(raw_bytes, padding: false)

      {:ok, media_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_media_edge",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [
                  %{
                    "type" => "image",
                    "data" => "not valid base64!!",
                    "mime_type" => "image/png"
                  },
                  %{
                    "type" => "image",
                    "data" => " #{url_safe_unpadded}\n",
                    "mime_type" => "image/png"
                  }
                ]
              },
              %{"type" => "google_search_call", "arguments" => "non-map"},
              %{"type" => "google_search_call", "arguments" => %{"queries" => ["q1", "q2"]}},
              %{"type" => "file_search_call"},
              %{"type" => "code_execution_call"},
              %{"type" => "url_context_call"}
            ],
            "usage" => %{"total_input_tokens" => 5, "total_output_tokens" => 5}
          },
          model,
          Context.new([Context.user("Media")]),
          []
        )

      assert [
               %ContentPart{type: :provider_block, data: %{"data" => "not valid base64!!"}},
               %ContentPart{type: :image, data: ^raw_bytes},
               %ContentPart{type: :provider_block},
               %ContentPart{type: :provider_block},
               %ContentPart{type: :provider_block},
               %ContentPart{type: :provider_block},
               %ContentPart{type: :provider_block}
             ] = media_resp.message.content

      assert media_resp.usage.tool_usage.web_search == %{count: 3, unit: :query}
      assert media_resp.usage.tool_usage.file_search == %{count: 1, unit: :call}
      assert media_resp.usage.tool_usage.code_execution == %{count: 1, unit: :call}
      assert media_resp.usage.tool_usage.url_context == %{count: 1, unit: :call}
    end

    test "slices multi-turn history to latest turn, skips function_result, and generates fallback call IDs" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, multi_turn_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_multi",
            "status" => "completed",
            "steps" => [
              %{"type" => "user_input", "content" => "Check weather"},
              %{
                "type" => "function_call",
                "id" => "call_old_1",
                "name" => "get_weather",
                "arguments" => %{"city" => "NYC"}
              },
              %{
                "type" => "function_result",
                "call_id" => "call_old_1",
                "name" => "get_weather",
                "result" => "72F"
              },
              %{
                "type" => "thought",
                "signature" => "sig_turn2",
                "summary" => [%{"type" => "text", "text" => "Thinking"}]
              },
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "It is 72F in NYC."}]
              }
            ]
          },
          model,
          Context.new([Context.user("Check weather")])
        )

      assert multi_turn_resp.finish_reason == :stop
      assert ReqLLM.Response.tool_calls(multi_turn_resp) == []
      assert ReqLLM.Response.text(multi_turn_resp) == "It is 72F in NYC."
      assert multi_turn_resp.provider_meta["builtin_tools"] == nil

      refute Enum.any?(
               multi_turn_resp.message.content,
               &match?(%ContentPart{type: :provider_block}, &1)
             )

      assert [
               %{"type" => "thought", "signature" => "sig_turn2"},
               %{"type" => "model_output"}
             ] = InteractionsAPI.verified_interactions_steps(multi_turn_resp.message)

      assert {:ok, unnamed_fc_resp} =
               InteractionsAPI.decode_interaction_body(
                 %{
                   "id" => "int_fallback_id",
                   "status" => "requires_action",
                   "steps" => [
                     %{"type" => "user_input", "content" => "Run"},
                     %{
                       "type" => "function_call",
                       "name" => "run_tool",
                       "arguments" => %{"ok" => true}
                     }
                   ]
                 },
                 model,
                 Context.new([Context.user("Run")])
               )

      assert [%{id: "call_int_fallback_id_1"}] = ReqLLM.Response.tool_calls(unnamed_fc_resp)
    end
  end

  describe "usage normalization and built-in tool metrics" do
    test "extracts basic usage from maps and ReqLLM.Response structs" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, extracted_usage} =
        Google.extract_usage(
          %{"usage" => %{"total_input_tokens" => 9, "total_output_tokens" => 4}},
          model
        )

      assert extracted_usage.input_tokens == 9
      assert extracted_usage.output_tokens == 4
      assert InteractionsAPI.interactions_usage_body?(%{"usage" => %{"total_tokens" => 12}})

      assert {:ok, %{total_tokens: 0, tool_usage: %{web_search: %{count: 2}}}} =
               Google.extract_usage(
                 %{
                   "usage" => %{
                     "grounding_tool_count" => [%{"tool" => "google_search", "count" => 2}]
                   }
                 },
                 model
               )

      assert {:ok, %{input_tokens: 7}} =
               Google.extract_usage(
                 %ReqLLM.Response{
                   id: "r1",
                   model: @model_id,
                   context: Context.new([]),
                   usage: %{input_tokens: 7}
                 },
                 model
               )
    end

    test "normalizes grounding_tool_count aliases, query fallback counts, and nil-usage tool steps" do
      {:ok, model} = ReqLLM.model(@model_id)

      query_model = %LLMDB.Model{
        id: "gemini-query-unit",
        provider: :google,
        pricing: %{
          components: [
            %{id: "tool.web_search", kind: "tool", tool: "web_search", unit: "query", rate: 0.01}
          ]
        }
      }

      {:ok, fallback_call_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_empty_queries",
            "status" => "completed",
            "steps" => [%{"type" => "google_search_call"}],
            "usage" => %{"total_input_tokens" => 1, "total_output_tokens" => 1}
          },
          query_model,
          Context.new([Context.user("Search")])
        )

      assert fallback_call_resp.usage.tool_usage.web_search == %{count: 1, unit: :call}

      {:ok, nil_usage_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_no_usage",
            "status" => "requires_action",
            "steps" => [%{"type" => "google_search_call"}]
          },
          model,
          Context.new([Context.user("Search")])
        )

      assert nil_usage_resp.usage.tool_usage.web_search == %{count: 1, unit: :call}

      assert {:ok, grounding_resp} =
               InteractionsAPI.decode_interaction_body(
                 %{
                   "id" => "int_g_keys",
                   "status" => "completed",
                   "steps" => [],
                   "usage" => %{
                     "grounding_tool_count" => [
                       %{"tool" => "web_search", "count" => 1},
                       %{"tool" => "url_context_metadata", "count" => 2}
                     ]
                   }
                 },
                 model,
                 Context.new([Context.user("Search")])
               )

      assert grounding_resp.usage.tool_usage.web_search == %{count: 1, unit: :query}
      assert grounding_resp.usage.tool_usage.url_context == %{count: 2, unit: :call}
    end

    test "merges grounding_tool_count with non-grounding built-in tools and slices extract_usage" do
      {:ok, model} = ReqLLM.model(@model_id)

      body = %{
        "id" => "int_tools_usage",
        "object" => "interaction",
        "status" => "completed",
        "steps" => [
          %{"type" => "user_input", "content" => "Turn 1"},
          %{"type" => "code_execution_call", "id" => "ce_old"},
          %{"type" => "user_input", "content" => "Turn 2"},
          %{
            "type" => "google_search_call",
            "id" => "gs_1",
            "arguments" => %{"queries" => ["q1", "q2"]}
          },
          %{"type" => "code_execution_call", "id" => "ce_1"},
          %{"type" => "file_search_call", "id" => "fs_1"}
        ],
        "usage" => %{
          "total_input_tokens" => 10,
          "total_output_tokens" => 5,
          "total_tokens" => 15,
          "grounding_tool_count" => [
            %{"tool" => "google_search", "count" => 3},
            %{"tool" => "google_maps", "count" => 2}
          ]
        }
      }

      {:ok, decoded} =
        InteractionsAPI.decode_interaction_body(body, model, Context.new([Context.user("Go")]))

      {:ok, extracted} = Google.extract_usage(body, model)

      assert decoded.usage.tool_usage == %{
               web_search: %{count: 3, unit: :query},
               google_maps: %{count: 2, unit: :query},
               code_execution: %{count: 1, unit: :call},
               file_search: %{count: 1, unit: :call}
             }

      assert extracted == decoded.usage
    end

    test "preserves grounding tool usage precedence in attach_step_tool_usage/3" do
      {:ok, model} = ReqLLM.model(@model_id)

      grounding_usage =
        Decoder.normalize_usage(
          %{
            "total_input_tokens" => 10,
            "grounding_tool_count" => [%{"tool" => "google_search", "count" => 3}]
          },
          [],
          model
        )

      attached =
        Decoder.attach_step_tool_usage(
          grounding_usage,
          [
            %{"type" => "google_search_call", "arguments" => %{"queries" => ["q1"]}},
            %{"type" => "code_execution_call", "id" => "ce_1"}
          ],
          model
        )

      assert attached.tool_usage == %{
               web_search: %{count: 3, unit: :query},
               code_execution: %{count: 1, unit: :call}
             }
    end
  end
end
