defmodule ReqLLM.Providers.Google.InteractionsAPI.StreamingHTTPTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Google.InteractionsAPIHelpers, only: [sse_frame: 2]

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.StreamResponse
  alias ReqLLM.Test.Google.InteractionsAPIHelpers.SSEPlug

  @model_id "google:gemini-4-hydrogen"
  @api_key "test-stream-key"

  describe "attach_stream/4" do
    test "builds POST /v1/interactions for models and v1beta for agents without alt=sse" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Stream hello")])

      {:ok, finch_req} =
        Google.attach_stream(
          model,
          context,
          [api_key: @api_key, google_api: :interactions],
          :default
        )

      assert finch_req.method == "POST"
      assert finch_req.host == "generativelanguage.googleapis.com"
      assert finch_req.path == "/v1/interactions"
      assert finch_req.query == nil
      assert {"api-revision", "2026-05-20"} in finch_req.headers
      assert {"accept", "text/event-stream"} in finch_req.headers
      assert {"x-goog-api-key", @api_key} in finch_req.headers

      decoded = Jason.decode!(IO.iodata_to_binary(finch_req.body))
      assert decoded["model"] == "gemini-4-hydrogen"
      assert decoded["stream"] == true

      {:ok, custom_hdr_req} =
        Google.attach_stream(
          model,
          context,
          [
            api_key: @api_key,
            google_api: :interactions,
            req_http_options: [headers: [{"Accept", "application/x-ndjson"}]]
          ],
          :default
        )

      accept_headers =
        Enum.filter(custom_hdr_req.headers, fn {k, _} -> String.downcase(k) == "accept" end)

      assert accept_headers == [{"accept", "application/x-ndjson"}]

      {:ok, default_agent_req} =
        Google.attach_stream(
          model,
          context,
          [
            api_key: @api_key,
            agent: "deep-research-pro-preview-12-2025"
          ],
          :default
        )

      assert default_agent_req.path == "/v1beta/interactions"

      {:ok, explicit_v1beta_req} =
        Google.attach_stream(
          model,
          context,
          [
            api_key: @api_key,
            base_url: "https://generativelanguage.googleapis.com/v1beta/",
            google_api: :interactions
          ],
          :default
        )

      assert explicit_v1beta_req.path == "/v1beta/interactions"

      {:ok, explicit_v1_req} =
        Google.attach_stream(
          model,
          context,
          [
            api_key: @api_key,
            base_url: "https://generativelanguage.googleapis.com/v1",
            agent: "deep-research-pro-preview-12-2025"
          ],
          :default
        )

      assert explicit_v1_req.path == "/v1/interactions"

      {:ok, agent_req} =
        Google.attach_stream(
          model,
          context,
          [
            api_key: @api_key,
            agent: "deep-research-pro-preview-12-2025",
            google_auth_header: false
          ],
          :default
        )

      assert agent_req.path == "/v1beta/interactions"
      assert agent_req.query == URI.encode_query(key: @api_key)
      refute Enum.any?(agent_req.headers, fn {k, _} -> String.downcase(k) == "x-goog-api-key" end)
    end

    test "validates blank resume id, empty context, and unknown stream options" do
      {:ok, model} = ReqLLM.model(@model_id)
      context = Context.new([Context.user("Stream hello")])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Google.attach_stream(
                 model,
                 context,
                 [api_key: @api_key, interactions_resume_id: "   "],
                 :default
               )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Google.attach_stream(
                 model,
                 Context.new([]),
                 [api_key: @api_key, google_api: :interactions],
                 :default
               )

      assert {:error, _} =
               Google.attach_stream(
                 model,
                 Context.new([]),
                 [
                   api_key: @api_key,
                   interactions_resume_id: "int_invalid",
                   unknown_bad_opt: :nope
                 ],
                 :default
               )
    end

    test "strips content-type on resume GET and merges proxy base_url query params" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, resume_finch} =
        Google.attach_stream(
          model,
          Context.new([]),
          [api_key: @api_key, interactions_resume_id: "int_get_only"],
          nil
        )

      refute Enum.any?(resume_finch.headers, fn {k, _} -> k == "content-type" end)

      {:ok, param_finch} =
        Google.attach_stream(
          model,
          Context.new([Context.user("Hi")]),
          [
            api_key: @api_key,
            google_api: :interactions,
            base_url: "https://proxy.example.com/v1?tenant=acme",
            params: [trace: "1"],
            req_http_options: [params: [region: "us"]],
            provider_options: [google_auth_header: false]
          ],
          :default
        )

      assert param_finch.path == "/v1/interactions"
      decoded_query = URI.decode_query(param_finch.query)

      assert decoded_query == %{
               "tenant" => "acme",
               "region" => "us",
               "trace" => "1",
               "key" => @api_key
             }

      {:ok, req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions
        )

      assert req.options[:operation] == :chat
    end
  end

  describe "end-to-end Bandit HTTP streaming and resume parity" do
    test "stream_text/3 matches buffered Response shape and resume passes last_event_id" do
      events = [
        sse_frame(
          %{
            "event_type" => "interaction.created",
            "interaction" => %{
              "id" => "int_bandit_1",
              "model" => "gemini-4-hydrogen",
              "status" => "in_progress"
            }
          },
          "evt_1"
        ),
        sse_frame(
          %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}},
          "evt_2"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{
              "type" => "thought_summary",
              "content" => %{"type" => "text", "text" => "Checking "}
            }
          },
          "evt_3"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{
              "type" => "thought_summary",
              "content" => %{"type" => "text", "text" => "math"}
            }
          },
          "evt_3b"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 0,
            "delta" => %{"type" => "thought_signature", "signature" => "sig_bandit_0"}
          },
          "evt_4"
        ),
        sse_frame(%{"event_type" => "step.stop", "index" => 0}, "evt_5"),
        sse_frame(
          %{"event_type" => "step.start", "index" => 1, "step" => %{"type" => "model_output"}},
          "evt_6"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text", "text" => "42 is "}
          },
          "evt_7"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text", "text" => "the answer."}
          },
          "evt_8"
        ),
        sse_frame(%{"event_type" => "step.stop", "index" => 1}, "evt_9"),
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_bandit_1",
              "status" => "completed",
              "usage" => %{
                "total_input_tokens" => 6,
                "total_output_tokens" => 5,
                "total_thought_tokens" => 4,
                "total_tokens" => 15
              }
            }
          },
          "evt_10"
        ),
        "data: [DONE]\n\n"
      ]

      resume_events = [
        sse_frame(
          %{"event_type" => "step.start", "index" => 1, "step" => %{"type" => "model_output"}},
          "evt_8"
        ),
        sse_frame(
          %{
            "event_type" => "step.delta",
            "index" => 1,
            "delta" => %{"type" => "text", "text" => "42 is the answer."}
          },
          "evt_9"
        ),
        sse_frame(%{"event_type" => "step.stop", "index" => 1}, "evt_10"),
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_bandit_1",
              "status" => "completed",
              "steps" => [
                %{
                  "type" => "thought",
                  "signature" => "sig_bandit_0",
                  "summary" => [%{"type" => "text", "text" => "Checking math"}]
                },
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "42 is the answer."}]
                }
              ]
            }
          },
          "evt_99"
        )
      ]

      server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), events: events, resume_events: resume_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_stream_text_parity, make_ref()}
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      base_url = "http://127.0.0.1:#{port}/v1"

      {:ok, stream_response} =
        ReqLLM.stream_text(@model_id, "What is the answer?",
          api_key: @api_key,
          base_url: base_url,
          google_api: :interactions
        )

      {:ok, streamed_resp} = StreamResponse.to_response(stream_response)

      assert_receive {:post_stream, post_headers, post_body}, 1_000
      assert {"api-revision", "2026-05-20"} in post_headers
      assert post_body["stream"] == true

      buffered_payload = %{
        "id" => "int_bandit_1",
        "model" => "gemini-4-hydrogen",
        "status" => "completed",
        "steps" => [
          %{
            "type" => "thought",
            "signature" => "sig_bandit_0",
            "summary" => [%{"type" => "text", "text" => "Checking math"}]
          },
          %{
            "type" => "model_output",
            "content" => [%{"type" => "text", "text" => "42 is the answer."}]
          }
        ],
        "usage" => %{
          "total_input_tokens" => 6,
          "total_output_tokens" => 5,
          "total_thought_tokens" => 4,
          "total_tokens" => 15
        }
      }

      buffered_plug = fn conn ->
        Req.Test.json(%{conn | status: 200}, buffered_payload)
      end

      {:ok, buffered_resp} =
        ReqLLM.generate_text(@model_id, "What is the answer?",
          api_key: @api_key,
          google_api: :interactions,
          req_http_options: [plug: buffered_plug]
        )

      assert ReqLLM.Response.text(streamed_resp) == ReqLLM.Response.text(buffered_resp)
      assert ReqLLM.Response.thinking(streamed_resp) == ReqLLM.Response.thinking(buffered_resp)
      assert streamed_resp.message.reasoning_details == buffered_resp.message.reasoning_details
      assert streamed_resp.finish_reason == buffered_resp.finish_reason
      assert Map.take(streamed_resp.usage, Map.keys(buffered_resp.usage)) == buffered_resp.usage
      assert ReqLLM.Response.usage(streamed_resp).input_tokens == 6
      assert ReqLLM.Response.usage(streamed_resp).output_tokens == 9
      assert ReqLLM.Response.usage(streamed_resp).reasoning_tokens == 4
      assert ReqLLM.Response.usage(streamed_resp).total_tokens == 15
      assert streamed_resp.provider_meta["interaction_id"] == "int_bandit_1"
      assert streamed_resp.provider_meta["last_event_id"] == "evt_10"

      assert is_list(InteractionsAPI.verified_interactions_steps(streamed_resp.message))

      {:ok, resumed} =
        InteractionsAPI.stream("int_bandit_1",
          api_key: @api_key,
          base_url: base_url,
          last_event_id: "evt_2"
        )

      {:ok, resumed_resp} = StreamResponse.to_response(resumed)

      assert_receive {:get_resume, "int_bandit_1", query_params, resume_headers}, 1_000
      assert {"api-revision", "2026-05-20"} in resume_headers
      assert query_params == %{"stream" => "true", "last_event_id" => "evt_2"}
      assert resumed_resp.provider_meta["last_event_id"] == "evt_99"

      assert [
               %{"type" => "thought", "signature" => "sig_bandit_0"},
               %{"type" => "model_output"}
             ] = InteractionsAPI.verified_interactions_steps(resumed_resp.message)
    end

    test "ReqLLM.stream_object/4 populates response.object for JSON objects and arrays" do
      for {json_payload, schema, expected} <- [
            {~s({"answer":42}), [answer: [type: :integer, required: true]], %{"answer" => 42}},
            {~s([{"id":1}]), [items: [type: {:list, :map}]], [%{"id" => 1}]}
          ] do
        obj_events = [
          sse_frame(
            %{
              "event_type" => "interaction.created",
              "interaction" => %{
                "id" => "int_obj_stream",
                "model" => "gemini-4-hydrogen",
                "status" => "in_progress",
                "response_format" => %{"type" => "text", "mime_type" => "application/json"}
              }
            },
            "evt_o1"
          ),
          sse_frame(
            %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "model_output"}},
            "evt_o2"
          ),
          sse_frame(
            %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "text", "text" => json_payload}
            },
            "evt_o3"
          ),
          sse_frame(%{"event_type" => "step.stop", "index" => 0}, "evt_o4"),
          sse_frame(
            %{
              "event_type" => "interaction.completed",
              "interaction" => %{"id" => "int_obj_stream", "status" => "completed"}
            },
            "evt_o5"
          ),
          "data: [DONE]\n\n"
        ]

        server =
          start_supervised!(
            {Bandit,
             plug: {SSEPlug, owner: self(), events: obj_events},
             port: 0,
             ip: {127, 0, 0, 1},
             startup_log: false},
            id: {:bandit_obj, make_ref()}
          )

        {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
        base_url = "http://127.0.0.1:#{port}/v1"

        {:ok, stream_resp} =
          ReqLLM.stream_object(@model_id, "Extract", schema,
            api_key: @api_key,
            base_url: base_url,
            google_api: :interactions
          )

        {:ok, resp} = StreamResponse.to_response(stream_resp)
        assert resp.object == expected
      end
    end

    test "plain :chat keeps resp.object nil for JSON while :object unwraps without format" do
      for payload_text <- [~s({"ok":true}), ~s([1,2,3])] do
        events = [
          sse_frame(
            %{
              "event_type" => "interaction.created",
              "interaction" => %{
                "id" => "int_chat_stream_json",
                "model" => "gemini-4-hydrogen",
                "status" => "in_progress"
              }
            },
            "evt_c1"
          ),
          sse_frame(
            %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "model_output"}},
            "evt_c2"
          ),
          sse_frame(
            %{
              "event_type" => "step.delta",
              "index" => 0,
              "delta" => %{"type" => "text", "text" => payload_text}
            },
            "evt_c3"
          ),
          sse_frame(%{"event_type" => "step.stop", "index" => 0}, "evt_c4"),
          sse_frame(
            %{
              "event_type" => "interaction.completed",
              "interaction" => %{"id" => "int_chat_stream_json", "status" => "completed"}
            },
            "evt_c5"
          ),
          "data: [DONE]\n\n"
        ]

        server =
          start_supervised!(
            {Bandit,
             plug: {SSEPlug, owner: self(), events: events},
             port: 0,
             ip: {127, 0, 0, 1},
             startup_log: false},
            id: {:bandit_chat_json, make_ref()}
          )

        {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
        base_url = "http://127.0.0.1:#{port}/v1"

        {:ok, chat_stream} =
          ReqLLM.stream_text(@model_id, "Reply",
            api_key: @api_key,
            base_url: base_url,
            google_api: :interactions
          )

        {:ok, chat_resp} = StreamResponse.to_response(chat_stream)
        assert ReqLLM.Response.text(chat_resp) == payload_text
        assert chat_resp.object == nil

        {:ok, obj_stream} =
          ReqLLM.stream_object(@model_id, "Extract", [ok: [type: :boolean]],
            api_key: @api_key,
            base_url: base_url,
            google_api: :interactions
          )

        {:ok, obj_resp} = StreamResponse.to_response(obj_stream)
        assert obj_resp.object == Jason.decode!(payload_text)
      end
    end

    test "handles [DONE]-only resume streams without stale tool history" do
      server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), resume_events: ["data: [DONE]\n\n"]},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_done_only, make_ref()}
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      base_url = "http://127.0.0.1:#{port}/v1"

      {:ok, done_stream} =
        InteractionsAPI.stream("done_only",
          api_key: @api_key,
          base_url: base_url
        )

      {:ok, done_resp} = StreamResponse.to_response(done_stream)
      assert_receive {:get_resume, "done_only", _query, _headers}, 1_000
      assert done_resp.id == "done_only"
      assert done_resp.provider_meta["google_tool_history"] == nil
    end

    test "decodes snapshot-only interaction.completed stream when resuming" do
      snapshot_events = [
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_snapshot_done",
              "status" => "requires_action",
              "steps" => [
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "Calling"}]
                },
                %{
                  "type" => "function_call",
                  "id" => "fc_snap",
                  "name" => "lookup",
                  "arguments" => %{"q" => "elixir"}
                }
              ]
            }
          },
          "evt_snap"
        ),
        "data: [DONE]\n\n"
      ]

      snap_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), resume_events: snapshot_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_snapshot, make_ref()}
        )

      {:ok, {_addr, snap_port}} = ThousandIsland.listener_info(snap_server)
      snap_base_url = "http://127.0.0.1:#{snap_port}/v1"

      {:ok, snap_stream} =
        InteractionsAPI.stream("int_snapshot_done",
          api_key: @api_key,
          base_url: snap_base_url
        )

      {:ok, snap_resp} = StreamResponse.to_response(snap_stream)
      assert ReqLLM.Response.text(snap_resp) == "Calling"
      assert snap_resp.finish_reason == :tool_calls

      assert [%{id: "fc_snap", function: %{name: "lookup"}}] =
               ReqLLM.Response.tool_calls(snap_resp)
    end

    test "preserves model name on [DONE]-only resume from existing Response struct" do
      bg_resp = %ReqLLM.Response{
        id: "done_only_model",
        model: "gemini-4-hydrogen",
        context: Context.new([]),
        provider_meta: %{}
      }

      done_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), resume_events: ["data: [DONE]\n\n"]},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_resp_model, make_ref()}
        )

      {:ok, {_addr, done_port}} = ThousandIsland.listener_info(done_server)

      {:ok, model_stream} =
        InteractionsAPI.stream(bg_resp,
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{done_port}/v1"
        )

      {:ok, model_resumed_resp} = StreamResponse.to_response(model_stream)
      assert model_resumed_resp.model == "gemini-4-hydrogen"
    end

    test "falls back from v1 404 to v1beta GET stream when resuming" do
      beta_events = [
        sse_frame(
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{
              "id" => "int_agent_404",
              "agent" => "deep-research-pro-preview-12-2025",
              "status" => "completed",
              "steps" => [
                %{
                  "type" => "model_output",
                  "content" => [%{"type" => "text", "text" => "Beta streamed"}]
                }
              ]
            }
          },
          "evt_b1"
        ),
        "data: [DONE]\n\n"
      ]

      beta_server =
        start_supervised!(
          {Bandit,
           plug: {SSEPlug, owner: self(), v1_not_found: true, v1beta_resume_events: beta_events},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: {:bandit_v1beta_fallback, make_ref()}
        )

      {:ok, {_addr, beta_port}} = ThousandIsland.listener_info(beta_server)

      {:ok, fallback_stream} =
        InteractionsAPI.stream("int_agent_404",
          api_key: @api_key,
          base_url: "http://127.0.0.1:#{beta_port}/v1"
        )

      {:ok, fallback_resp} = StreamResponse.to_response(fallback_stream)
      assert_receive {:get_resume, "int_agent_404", _, _}, 1_000
      assert_receive {:get_resume_v1beta, "int_agent_404", _, _}, 1_000
      assert ReqLLM.Response.text(fallback_resp) == "Beta streamed"
    end
  end
end
