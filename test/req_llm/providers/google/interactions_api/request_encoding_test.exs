defmodule ReqLLM.Providers.Google.InteractionsAPI.RequestEncodingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.InteractionsAPI.StepHistory
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @model_id "google:gemini-4-hydrogen"
  @api_key "test-google-key"

  describe "basic and multimodal encoding" do
    test "strips model prefix and encodes system_instruction, generation_config, and multimodal input" do
      context =
        Context.new([
          Context.system("System line 1"),
          Context.system("System line 2"),
          Context.user([
            ContentPart.text("Inspect these assets"),
            ContentPart.image(<<1, 2, 3>>, "image/png"),
            ContentPart.image_url("https://example.com/chart.png", %{mime_type: "image/png"}),
            ContentPart.file_id("https://example.com/deck.pdf", "application/pdf")
          ])
        ])

      prefixed_model = LLMDB.Model.new!(%{id: "models/gemini-4-hydrogen", provider: :google})

      {:ok, req} =
        Google.prepare_request(:chat, prefixed_model, context,
          api_key: @api_key,
          google_api: :interactions,
          max_tokens: 256,
          seed: 42,
          stop: ["DONE"],
          provider_options: [service_tier: :priority, store: true, background: false]
        )

      body = Google.encode_body(req).options[:json]

      assert body["model"] == "gemini-4-hydrogen"
      assert body["system_instruction"] == "System line 1\n\nSystem line 2"
      assert body["store"] == true
      assert body["background"] == false
      assert body["service_tier"] == "priority"
      assert body["generation_config"]["max_output_tokens"] == 256
      assert body["generation_config"]["seed"] == 42
      assert body["generation_config"]["stop_sequences"] == ["DONE"]
      refute Map.has_key?(body["generation_config"], "thinking_summaries")

      assert [
               %{"type" => "text", "text" => "Inspect these assets"},
               %{"type" => "image", "data" => base64_img, "mime_type" => "image/png"},
               %{
                 "type" => "image",
                 "uri" => "https://example.com/chart.png",
                 "mime_type" => "image/png"
               },
               %{
                 "type" => "document",
                 "uri" => "https://example.com/deck.pdf",
                 "mime_type" => "application/pdf"
               }
             ] = body["input"]

      assert Base.decode64!(base64_img) == <<1, 2, 3>>
    end

    test "converts GenerateContent safety settings to Interactions settings" do
      {:ok, request} =
        Google.prepare_request(:chat, @model_id, "Hello",
          api_key: @api_key,
          google_api: :interactions,
          google_safety_settings: [
            %{category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_MEDIUM_AND_ABOVE"},
            %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE", method: "SEVERITY"}
          ]
        )

      assert Google.encode_body(request).options[:json]["safety_settings"] == [
               %{"type" => "hate_speech", "threshold" => "block_medium_and_above"},
               %{"type" => "harassment", "threshold" => "off", "method" => "severity"}
             ]
    end

    test "isolates Managed Agent requests from model, generation_config, system_instruction, tools, response_format, and safety_settings" do
      {:ok, agent_req} =
        Google.prepare_request(:chat, @model_id, "Research Elixir",
          api_key: @api_key,
          agent: "deep-research-pro-preview-12-2025",
          background: true,
          max_tokens: 500,
          agent_config: %{"thinking_summaries" => "auto"},
          environment: "sandbox-1"
        )

      agent_body = Google.encode_body(agent_req).options[:json]
      assert agent_body["agent"] == "deep-research-pro-preview-12-2025"
      assert agent_body["agent_config"] == %{"thinking_summaries" => "auto"}
      assert agent_body["environment"] == "sandbox-1"
      refute Map.has_key?(agent_body, "model")
      refute Map.has_key?(agent_body, "generation_config")

      agent_tool =
        Tool.new!(
          name: "lookup",
          description: "Lookup",
          parameter_schema: [q: [type: :string]],
          callback: fn _ -> {:ok, "ok"} end
        )

      isolated_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.system("Ignore me"), Context.user("Research")]),
          agent: "deep-research-pro-preview-12-2025",
          system_prompt: "Also ignore",
          tools: [agent_tool],
          response_format: %{"type" => "text"},
          google_safety_settings: [%{"category" => "HARM_CATEGORY_HATE_SPEECH"}]
        )

      assert isolated_body["agent"] == "deep-research-pro-preview-12-2025"
      refute Map.has_key?(isolated_body, "model")
      refute Map.has_key?(isolated_body, "generation_config")
      refute Map.has_key?(isolated_body, "system_instruction")
      refute Map.has_key?(isolated_body, "tools")
      refute Map.has_key?(isolated_body, "response_format")
      refute Map.has_key?(isolated_body, "safety_settings")
    end

    test "encodes :labels, :system_prompt fallback, non-base64 data URIs, extensionless File URIs, and empty/nil user content" do
      {:ok, label_req} =
        Google.prepare_request(:chat, @model_id, "Labelled",
          api_key: @api_key,
          google_api: :interactions,
          provider_options: [labels: %{"env" => "prod"}]
        )

      assert Google.encode_body(label_req).options[:json]["labels"] == %{"env" => "prod"}

      {:ok, explicit_beta_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions,
          base_url: "https://generativelanguage.googleapis.com/v1beta"
        )

      assert explicit_beta_req.options[:base_url] ==
               "https://generativelanguage.googleapis.com/v1beta"

      uri_struct = URI.parse("https://example.com/item?id=1")

      context =
        Context.new([
          Context.user([
            ContentPart.image_url("data:text/plain,Hello%20World"),
            ContentPart.image_url("data:;base64,SGVsbG8=")
          ]),
          %Message{
            role: :assistant,
            content: [
              ContentPart.text("Looked up", %{annotations: [%{"type" => "url_citation"}]}),
              ContentPart.provider_block(:google, %{"type" => "file_search_call", "id" => "fs_1"})
            ],
            tool_calls: [ToolCall.new("c1", "fetch", "{}")]
          },
          %Message{
            role: :tool,
            name: "fetch",
            tool_call_id: "c1",
            content: [],
            metadata: %{tool_output: %{link: uri_struct}}
          },
          Context.user("Next")
        ])

      body =
        InteractionsAPI.build_request_body(@model_id, context,
          google_api: :interactions,
          tools: [
            %{
              type: "function",
              name: "raw_fn",
              parameters: %{
                "$schema" => "https://json-schema.org/draft/2020-12/schema",
                "type" => "object"
              }
            }
          ]
        )

      assert [%{"type" => "function", "name" => "raw_fn", "parameters" => %{"type" => "object"}}] =
               body["tools"]

      [user_step_1, model_step, fs_step, fc_step, fr_step, _user_step_2] = body["input"]

      assert [
               %{"type" => "document", "mime_type" => "text/plain", "data" => b64_plain},
               %{"type" => "document", "mime_type" => "text/plain", "data" => "SGVsbG8="}
             ] = user_step_1["content"]

      assert Base.decode64!(b64_plain) == "Hello World"
      assert model_step["type"] == "model_output"
      assert fs_step["type"] == "file_search_call"
      assert fc_step["type"] == "function_call"

      assert [%{"type" => "text", "text" => result_json}] = fr_step["result"]

      assert Jason.decode!(result_json) == %{
               "link" => %{
                 "authority" => "example.com",
                 "fragment" => nil,
                 "host" => "example.com",
                 "path" => "/item",
                 "port" => 443,
                 "query" => "id=1",
                 "scheme" => "https",
                 "userinfo" => nil
               }
             }

      fallback_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            %Message{role: :user, content: nil},
            Context.user([
              %ContentPart{type: :file, data: "", file_id: "https://example.com/a.pdf"}
            ])
          ]),
          google_api: :interactions,
          system_prompt: "Sys fallback",
          tool_choice: %{name: :get_weather},
          tools: [%{type: :google_search}],
          labels: %{coords: {"a", :b}},
          provider_options: [
            response_format: %{type: "text", mime_type: "application/json"},
            service_tier: false
          ]
        )

      assert fallback_body["system_instruction"] == "Sys fallback"

      assert fallback_body["response_format"] == %{
               "type" => "text",
               "mime_type" => "application/json"
             }

      assert fallback_body["tools"] == [%{"type" => "google_search"}]
      assert fallback_body["labels"] == %{"coords" => ["a", :b]}
      refute Map.has_key?(fallback_body, "service_tier")

      assert get_in(fallback_body, ["generation_config", "tool_choice"]) == %{
               "allowed_tools" => %{"mode" => "any", "tools" => ["get_weather"]}
             }

      assert [
               %{"type" => "user_input", "content" => [%{"type" => "text", "text" => ""}]},
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "document", "uri" => "https://example.com/a.pdf"}]
               }
             ] = fallback_body["input"]

      assert_raise Parameter, ~r/ContentPart :image requires non-empty/, fn ->
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user([%ContentPart{type: :image, data: nil}])]),
          google_api: :interactions
        )
      end

      single_empty_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user([ContentPart.text("")])]),
          google_api: :interactions
        )

      assert single_empty_body["input"] == ""

      multi_empty_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user([ContentPart.text("")]), Context.assistant("Ok")]),
          google_api: :interactions
        )

      assert [%{"type" => "user_input", "content" => [%{"type" => "text", "text" => ""}]}, _] =
               multi_empty_body["input"]
    end

    test "resolves image URLs without file extensions, replays extensionless audio File URIs, and keeps application/ogg audio type" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, audio_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_audio",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [
                  %{
                    "type" => "audio",
                    "uri" => "https://generativelanguage.googleapis.com/v1beta/files/abc123"
                  },
                  %{
                    "type" => "text",
                    "text" => "Transcript",
                    "annotations" => [%{"type" => "file_citation", "file_name" => "f1"}]
                  }
                ]
              }
            ],
            "usage" => %{
              "total_input_tokens" => 1,
              "total_output_tokens" => 1,
              "grounding_tool_count" => [
                %{"tool" => "google_search", "count" => 1},
                %{"tool" => "google_search", "count" => 2}
              ]
            }
          },
          model,
          Context.new([Context.user("Audio")])
        )

      assert audio_resp.usage.tool_usage.web_search.count == 3
      assert audio_resp.usage.tool_usage.web_search.unit == :query

      reconstructed_audio_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Audio"),
            %{audio_resp.message | metadata: %{}},
            Context.user("Again")
          ]),
          google_api: :interactions
        )

      [_, replayed_model_output, _] = reconstructed_audio_body["input"]

      assert replayed_model_output["content"] == [
               %{
                 "type" => "audio",
                 "uri" => "https://generativelanguage.googleapis.com/v1beta/files/abc123"
               },
               %{
                 "type" => "text",
                 "text" => "Transcript",
                 "annotations" => [%{"type" => "file_citation", "file_name" => "f1"}]
               }
             ]

      {:ok, ogg_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_ogg",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [
                  %{
                    "type" => "audio",
                    "data" => Base.encode64(<<1, 2, 3>>),
                    "mime_type" => "application/ogg"
                  }
                ]
              }
            ]
          },
          model,
          Context.new([Context.user("Audio")])
        )

      ogg_replay =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Audio"),
            %{ogg_resp.message | metadata: %{}},
            Context.user("Again")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "audio", "mime_type" => "application/ogg"}]
               },
               %{"type" => "user_input"}
             ] = ogg_replay["input"]
    end
  end

  describe "stateful previous_interaction_id deltas and resume requests" do
    test "encodes stateful previous_interaction_id trailing user delta and trailing tool results" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, tool_turn_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_turn_1",
            "status" => "requires_action",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "Checking weather"}]
              },
              %{
                "type" => "function_call",
                "id" => "call_w1",
                "name" => "get_weather",
                "arguments" => %{"city" => "SF"}
              },
              %{
                "type" => "function_call",
                "id" => "call_w2",
                "name" => "get_weather",
                "arguments" => %{"city" => "NYC"}
              }
            ]
          },
          model,
          Context.new([Context.user("What is the weather?")])
        )

      assert tool_turn_resp.message.metadata["interaction_id"] == "int_turn_1"

      context_with_tools =
        Context.new([
          Context.user("What is the weather?"),
          tool_turn_resp.message,
          Context.tool_result_message("get_weather", "call_w1", %{temp_c: 18}),
          Context.tool_result_message("get_weather", "call_w2", %{temp_c: 22})
        ])

      {:ok, tool_delta_req} =
        Google.prepare_request(:chat, @model_id, context_with_tools,
          api_key: @api_key,
          previous_interaction_id: "int_turn_1"
        )

      tool_delta_body = Google.encode_body(tool_delta_req).options[:json]
      assert tool_delta_body["previous_interaction_id"] == "int_turn_1"

      assert tool_delta_body["input"] == [
               %{
                 "type" => "function_result",
                 "call_id" => "call_w1",
                 "name" => "get_weather",
                 "result" => [%{"type" => "text", "text" => ~s({"temp_c":18})}]
               },
               %{
                 "type" => "function_result",
                 "call_id" => "call_w2",
                 "name" => "get_weather",
                 "result" => [%{"type" => "text", "text" => ~s({"temp_c":22})}]
               }
             ]

      {:ok, text_turn_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_turn_text",
            "status" => "completed",
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => "First answer"}]
              }
            ]
          },
          model,
          Context.new([Context.user("First question")])
        )

      user_followup_context =
        Context.new([
          Context.user("First question"),
          text_turn_resp.message,
          Context.user("Second question")
        ])

      {:ok, user_delta_req} =
        Google.prepare_request(:chat, @model_id, user_followup_context,
          api_key: @api_key,
          previous_interaction_id: "int_turn_text"
        )

      user_delta_body = Google.encode_body(user_delta_req).options[:json]
      assert user_delta_body["input"] == "Second question"

      unmatched_mixed_context =
        Context.new([
          Context.user("Q1"),
          %Message{
            role: :assistant,
            content: [ContentPart.text("Calling")],
            tool_calls: [ToolCall.new("call_m1", "lookup", ~s({"q":"a"}))]
          },
          Context.tool_result_message("lookup", "call_m1", %{ok: true}),
          Context.user("Follow-up note")
        ])

      {:ok, mixed_delta_req} =
        Google.prepare_request(:chat, @model_id, unmatched_mixed_context,
          api_key: @api_key,
          previous_interaction_id: "int_unmatched"
        )

      mixed_delta_body = Google.encode_body(mixed_delta_req).options[:json]

      assert mixed_delta_body["input"] == [
               %{
                 "type" => "function_result",
                 "call_id" => "call_m1",
                 "name" => "lookup",
                 "result" => [%{"type" => "text", "text" => ~s({"ok":true})}]
               },
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "text", "text" => "Follow-up note"}]
               }
             ]

      missing_followup_context =
        Context.new([Context.user("First question"), text_turn_resp.message])

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, missing_followup_context,
                 api_key: @api_key,
                 previous_interaction_id: "int_turn_text"
               )

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(@model_id, missing_followup_context,
          previous_interaction_id: "int_turn_text"
        )
      end

      unmatched_missing_followup =
        Context.new([
          Context.user("Q1"),
          %Message{role: :assistant, content: [ContentPart.text("No followup")]}
        ])

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(@model_id, unmatched_missing_followup,
          previous_interaction_id: "int_other"
        )
      end
    end

    test "preserves multi-message new turns with previous_interaction_id and ignores nil/blank prev_id matches" do
      multi_user_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Background context"), Context.user("Actual question")]),
          google_api: :interactions,
          previous_interaction_id: "int_prev_multi"
        )

      assert [
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "text", "text" => "Background context"}]
               },
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "text", "text" => "Actual question"}]
               }
             ] = multi_user_body["input"]

      tool_and_user_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.tool_result("fc_9", "lookup", "42"),
            Context.user("Also format nicely")
          ]),
          google_api: :interactions,
          previous_interaction_id: "int_prev_tool"
        )

      assert [
               %{"type" => "function_result", "call_id" => "fc_9"},
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "text", "text" => "Also format nicely"}]
               }
             ] = tool_and_user_body["input"]

      msgs_with_nil_tail = [
        Context.user("u1"),
        %Message{
          role: :assistant,
          content: [ContentPart.text("a1")],
          metadata: %{"interaction_id" => "int_1"}
        },
        Context.user("u2"),
        %Message{role: :assistant, content: [ContentPart.text("a2")], metadata: nil},
        Context.user("u3")
      ]

      assert StepHistory.select_stateful_delta(msgs_with_nil_tail, nil) == [
               List.last(msgs_with_nil_tail)
             ]

      assert StepHistory.select_stateful_delta(msgs_with_nil_tail, "   ") == [
               List.last(msgs_with_nil_tail)
             ]

      for key <- [:previous_interaction_id, :last_event_id, :continuation_token] do
        assert {:error, %Parameter{}} =
                 InteractionsAPI.validate_options([{:google_api, :interactions}, {key, "   "}])
      end
    end

    test "builds resume GET requests, skips prefill/body encoding, and forces stream: true" do
      {:ok, resume_req} =
        Google.prepare_request(:chat, @model_id, "",
          api_key: @api_key,
          interactions_resume_id: "int_resume/1",
          last_event_id: "evt_7",
          provider_options: [google_auth_header: false]
        )

      assert resume_req.method == :get
      assert resume_req.url.path == "/interactions/int_resume%2F1"

      assert Keyword.get(resume_req.options[:params], :stream) == "true"
      assert Keyword.get(resume_req.options[:params], :last_event_id) == "evt_7"
      assert Keyword.get(resume_req.options[:params], :key) == @api_key
      assert Req.Request.get_header(resume_req, "accept") == ["text/event-stream"]

      encoded_resume = Google.encode_body(resume_req)
      assert encoded_resume.options[:json] == nil

      {:ok, create_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions
        )

      assert create_req.options[:receive_timeout] ==
               Application.get_env(:req_llm, :receive_timeout, 120_000)

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "",
                 api_key: @api_key,
                 interactions_resume_id: "   "
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hi",
                 api_key: @api_key,
                 google_api: :interactions,
                 service_tier: false
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hi",
                 api_key: @api_key,
                 google_api: :interactions,
                 service_tier: "  "
               )

      assistant_ctx = Context.new([Context.user("Hi"), Context.assistant("Partial")])

      {:ok, prefill_resume_req} =
        Google.prepare_request(:chat, @model_id, assistant_ctx,
          api_key: @api_key,
          interactions_resume_id: "int_resume_stream"
        )

      assert prefill_resume_req.method == :get
      assert prefill_resume_req.options[:stream] == true

      {_req, resp} =
        Google.decode_response(
          {prefill_resume_req, Req.Response.new(status: 200, body: Elixir.Stream.map([], & &1))}
        )

      assert %ReqLLM.Response{stream?: true} = resp.body

      {:ok, nested_resume_req} =
        Google.prepare_request(:chat, @model_id, "Ignored",
          api_key: @api_key,
          provider_options: [
            google_api: :interactions,
            interactions_resume_id: "int_nested_resume"
          ]
        )

      encoded_nested_resume = Google.encode_body(nested_resume_req)
      assert encoded_nested_resume.method == :get
      assert encoded_nested_resume.options[:json] == nil
    end

    test "re-validates mutated options on encode_body" do
      {:ok, model} = ReqLLM.model(@model_id)

      mutated_req =
        Req.new(url: "/interactions", method: :post)
        |> Google.attach(model, api_key: @api_key, provider_options: [google_api: :interactions])
        |> Req.Request.merge_options(store: false, previous_interaction_id: "int_prev")

      assert_raise Parameter, fn ->
        Google.encode_body(mutated_req)
      end
    end
  end

  describe "stateless StepList replay and thought signature preservation" do
    test "encodes verbatim replay, reconstructed fallback, error results, and provider block filtering" do
      recorded_steps = [
        %{"type" => "thought", "signature" => "sig_recorded"},
        %{
          "type" => "google_search_call",
          "id" => "gs_1",
          "arguments" => %{"queries" => ["elixir"]}
        },
        %{
          "type" => "function_call",
          "id" => "call_1",
          "name" => "calc",
          "arguments" => %{"x" => 2}
        }
      ]

      verbatim_assistant = %Message{
        role: :assistant,
        content: [ContentPart.text("Let me calculate")],
        tool_calls: [ToolCall.new("call_1", "calc", ~s({"x":2}))]
      }

      verbatim_resp =
        InteractionsAPI.preserve_interactions_steps(
          %ReqLLM.Response{
            id: "int_1",
            model: "gemini-4-hydrogen",
            context: Context.new([]),
            message: verbatim_assistant
          },
          recorded_steps
        )

      reconstructed_assistant = %Message{
        role: :assistant,
        reasoning_details: [
          %Message.ReasoningDetails{
            text: "Checking both tools",
            signature: "sig_recon",
            encrypted?: true,
            provider: :google,
            format: "google-interactions-v1",
            index: 0
          }
        ],
        content: [
          ContentPart.provider_block(:google, %{"type" => "code_execution_call", "id" => "ce_1"}),
          ContentPart.provider_block(:anthropic, %{"type" => "thinking", "thinking" => "foreign"}),
          ContentPart.text("Calling search", %{
            annotations: [%{"type" => "url_citation", "url" => "https://example.com"}]
          })
        ],
        tool_calls: [ToolCall.new("call_2", "fetch_doc", ~s({"id":"doc_9"}))]
      }

      error_tool_msg = %Message{
        role: :tool,
        tool_call_id: "call_2",
        content: [ContentPart.text("timeout reached")],
        metadata: %{is_error: true}
      }

      context =
        Context.new([
          Context.user("Start"),
          verbatim_resp.message,
          Context.tool_result_message("calc", "call_1", %{value: 4}),
          reconstructed_assistant,
          error_tool_msg,
          Context.user("Summarize")
        ])

      body = InteractionsAPI.build_request_body(@model_id, context, google_api: :interactions)

      assert body["input"] == [
               %{"type" => "user_input", "content" => [%{"type" => "text", "text" => "Start"}]},
               %{"type" => "thought", "signature" => "sig_recorded"},
               %{
                 "type" => "google_search_call",
                 "id" => "gs_1",
                 "arguments" => %{"queries" => ["elixir"]}
               },
               %{
                 "type" => "function_call",
                 "id" => "call_1",
                 "name" => "calc",
                 "arguments" => %{"x" => 2}
               },
               %{
                 "type" => "function_result",
                 "call_id" => "call_1",
                 "name" => "calc",
                 "result" => [%{"type" => "text", "text" => ~s({"value":4})}]
               },
               %{
                 "type" => "thought",
                 "signature" => "sig_recon",
                 "summary" => [%{"type" => "text", "text" => "Checking both tools"}]
               },
               %{"type" => "code_execution_call", "id" => "ce_1"},
               %{
                 "type" => "model_output",
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "Calling search",
                     "annotations" => [
                       %{"type" => "url_citation", "url" => "https://example.com"}
                     ]
                   }
                 ]
               },
               %{
                 "type" => "function_call",
                 "id" => "call_2",
                 "name" => "fetch_doc",
                 "arguments" => %{"id" => "doc_9"}
               },
               %{
                 "type" => "function_result",
                 "call_id" => "call_2",
                 "name" => "fetch_doc",
                 "result" => [%{"type" => "text", "text" => "timeout reached"}],
                 "is_error" => true
               },
               %{
                 "type" => "user_input",
                 "content" => [%{"type" => "text", "text" => "Summarize"}]
               }
             ]
    end

    test "resolves newest tool names on colliding call_ids across turns" do
      collision_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Turn 1"),
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [ToolCall.new("call_0", "old_tool", ~s({"v":1}))]
            },
            Context.tool_result_message("old_tool", "call_0", "old_res"),
            Context.user("Turn 2"),
            %Message{
              role: :assistant,
              content: [],
              tool_calls: [ToolCall.new("call_0", "new_tool", ~s({"v":2}))]
            },
            %Message{
              role: :tool,
              tool_call_id: "call_0",
              content: [],
              metadata: %{tool_output: {:ok, :done}}
            }
          ]),
          google_api: :interactions
        )

      latest_result = List.last(collision_body["input"])
      assert latest_result["type"] == "function_result"
      assert latest_result["name"] == "new_tool"
      assert latest_result["result"] == "{:ok, :done}"
    end

    test "reconstructs partial and string-keyed thoughts cleanly" do
      replay_msg = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "", metadata: %{}},
          ContentPart.text("Before"),
          %ContentPart{
            type: :provider_block,
            data: %{"type" => "google_search_call", "arguments" => %{"queries" => ["elixir"]}},
            metadata: %{"provider" => "google"}
          },
          ContentPart.text("After"),
          %ContentPart{type: :thinking, text: nil, metadata: %{}}
        ],
        reasoning_details: [
          %{text: "Partial atom thought"},
          %{"text" => "String thought", "signature" => "sig_str"},
          %{text: "", signature: nil}
        ]
      }

      replay_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("First"),
            replay_msg,
            %Message{role: :tool, tool_call_id: "c1", name: "fn1", content: []}
          ]),
          google_api: :interactions
        )

      [user_step, thought1, out1, search_step, out2, thought2, tool_res] = replay_body["input"]
      assert user_step["type"] == "user_input"

      assert thought1 == %{
               "type" => "thought",
               "summary" => [%{"type" => "text", "text" => "Partial atom thought"}]
             }

      assert out1 == %{
               "type" => "model_output",
               "content" => [%{"type" => "text", "text" => "Before"}]
             }

      assert search_step["type"] == "google_search_call"

      assert out2 == %{
               "type" => "model_output",
               "content" => [%{"type" => "text", "text" => "After"}]
             }

      assert thought2 == %{
               "type" => "thought",
               "signature" => "sig_str",
               "summary" => [%{"type" => "text", "text" => "String thought"}]
             }

      assert tool_res["result"] == ""
    end

    test "reconstruct_assistant_steps preserves order for mixed signature-only and summarized thoughts" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, resp1} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_mix_1",
            "status" => "requires_action",
            "steps" => [
              %{"type" => "thought", "signature" => "sig_0"},
              %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "Lead"}]},
              %{
                "type" => "thought",
                "signature" => "sig_2",
                "summary" => [%{"type" => "text", "text" => "Checking tool"}]
              },
              %{"type" => "function_call", "id" => "fc_1", "name" => "lookup", "arguments" => %{}}
            ]
          },
          model,
          Context.new([Context.user("Go")])
        )

      body1 =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Go"),
            %{resp1.message | metadata: %{}},
            Context.tool_result("fc_1", "lookup", "ok")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{"type" => "thought", "signature" => "sig_0"},
               %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "Lead"}]},
               %{
                 "type" => "thought",
                 "signature" => "sig_2",
                 "summary" => [%{"type" => "text", "text" => "Checking tool"}]
               },
               %{"type" => "function_call", "id" => "fc_1"},
               %{"type" => "function_result", "call_id" => "fc_1"}
             ] = body1["input"]

      {:ok, resp2} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_mix_2",
            "status" => "requires_action",
            "steps" => [
              %{
                "type" => "thought",
                "signature" => "sig_a",
                "summary" => [%{"type" => "text", "text" => "Initial plan"}]
              },
              %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "Middle"}]},
              %{"type" => "thought", "signature" => "sig_b"},
              %{"type" => "function_call", "id" => "fc_2", "name" => "lookup", "arguments" => %{}}
            ]
          },
          model,
          Context.new([Context.user("Go")])
        )

      body2 =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Go"),
            %{resp2.message | metadata: %{}},
            Context.tool_result("fc_2", "lookup", "ok")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "thought",
                 "signature" => "sig_a",
                 "summary" => [%{"type" => "text", "text" => "Initial plan"}]
               },
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "text", "text" => "Middle"}]
               },
               %{"type" => "thought", "signature" => "sig_b"},
               %{"type" => "function_call", "id" => "fc_2"},
               %{"type" => "function_result", "call_id" => "fc_2"}
             ] = body2["input"]
    end

    test "preserves summaryless reasoning details and does not steal reserved later thinking signatures" do
      summaryless_first_msg = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "thought A", metadata: %{}},
          %ContentPart{type: :thinking, text: "thought B", metadata: %{}}
        ],
        reasoning_details: [
          %Message.ReasoningDetails{text: nil, signature: "sig_A"},
          %Message.ReasoningDetails{text: "thought B", signature: "sig_B"}
        ]
      }

      summaryless_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Q1"), summaryless_first_msg, Context.user("Q2")]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "thought",
                 "signature" => "sig_A",
                 "summary" => [%{"type" => "text", "text" => "thought A"}]
               },
               %{
                 "type" => "thought",
                 "signature" => "sig_B",
                 "summary" => [%{"type" => "text", "text" => "thought B"}]
               },
               %{"type" => "user_input"}
             ] = summaryless_body["input"]

      reserved_sig_msg = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "thought A", metadata: %{}},
          %ContentPart{type: :thinking, text: "thought B", metadata: %{signature: "sig_B"}}
        ],
        reasoning_details: [
          %Message.ReasoningDetails{text: "thought B", signature: "sig_B"}
        ]
      }

      reserved_sig_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Q1"), reserved_sig_msg, Context.user("Q2")]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "thought",
                 "summary" => [%{"type" => "text", "text" => "thought A"}]
               },
               %{
                 "type" => "thought",
                 "signature" => "sig_B",
                 "summary" => [%{"type" => "text", "text" => "thought B"}]
               },
               %{"type" => "user_input"}
             ] = reserved_sig_body["input"]

      duplicate_text_msg = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "shared thought", metadata: %{}},
          %ContentPart{type: :thinking, text: "shared thought", metadata: %{signature: "sig_2"}}
        ],
        reasoning_details: [
          %Message.ReasoningDetails{text: nil, signature: "sig_1"},
          %Message.ReasoningDetails{text: "shared thought", signature: "sig_2"}
        ]
      }

      duplicate_text_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Q1"), duplicate_text_msg, Context.user("Q2")]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "thought",
                 "signature" => "sig_1",
                 "summary" => [%{"type" => "text", "text" => "shared thought"}]
               },
               %{
                 "type" => "thought",
                 "signature" => "sig_2",
                 "summary" => [%{"type" => "text", "text" => "shared thought"}]
               },
               %{"type" => "user_input"}
             ] = duplicate_text_body["input"]

      shared_text_only_reserved_msg = %Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "shared thought", metadata: %{}},
          %ContentPart{type: :thinking, text: "shared thought", metadata: %{signature: "sig_2"}}
        ],
        reasoning_details: [
          %Message.ReasoningDetails{text: "shared thought", signature: "sig_2"}
        ]
      }

      shared_text_only_reserved_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Q1"), shared_text_only_reserved_msg, Context.user("Q2")]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "thought",
                 "summary" => [%{"type" => "text", "text" => "shared thought"}]
               },
               %{
                 "type" => "thought",
                 "signature" => "sig_2",
                 "summary" => [%{"type" => "text", "text" => "shared thought"}]
               },
               %{"type" => "user_input"}
             ] = shared_text_only_reserved_body["input"]
    end

    test "preserves function_call signatures, normalizes missing IDs, skips unsigned empty thoughts, and filters foreign/empty provider_blocks" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_sig_fc",
            "status" => "requires_action",
            "steps" => [
              %{"type" => "thought"},
              %{
                "type" => "function_call",
                "name" => "lookup",
                "arguments" => %{"q" => "elixir"},
                "signature" => "sig_fc_1"
              },
              %{
                "type" => "model_output",
                "content" => [%{"type" => "custom_future_item", "payload" => %{"a" => 1}}]
              }
            ]
          },
          model,
          Context.new([Context.user("Go")])
        )

      assert resp.message.reasoning_details in [nil, []]

      assert [
               %{
                 id: "call_int_sig_fc_1",
                 function: %{metadata: %{signature: "sig_fc_1"}}
               }
             ] = ReqLLM.Response.tool_calls(resp)

      assert [
               %{
                 "type" => "function_call",
                 "id" => "call_int_sig_fc_1",
                 "name" => "lookup",
                 "signature" => "sig_fc_1"
               },
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "custom_future_item", "payload" => %{"a" => 1}}]
               }
             ] = InteractionsAPI.verified_interactions_steps(resp.message)

      assert [%ContentPart{type: :provider_block, data: %{"type" => "custom_future_item"}}] =
               resp.message.content

      replay_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("Go"),
            %{resp.message | metadata: %{}},
            Context.tool_result("call_int_sig_fc_1", "lookup", "ok")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{
                 "type" => "model_output",
                 "content" => [%{"type" => "custom_future_item", "payload" => %{"a" => 1}}]
               },
               %{
                 "type" => "function_call",
                 "id" => "call_int_sig_fc_1",
                 "name" => "lookup",
                 "signature" => "sig_fc_1"
               },
               %{"type" => "function_result", "call_id" => "call_int_sig_fc_1"}
             ] = replay_body["input"]

      mixed_assistant = %Message{
        role: :assistant,
        content: [
          ContentPart.provider_block(:google, %{"functionCall" => %{"name" => "gc"}}, %{
            api: :generate_content
          }),
          ContentPart.provider_block(:google, %{"type" => "custom_step", "v" => 1}, %{
            "provider" => "google",
            "api" => "interactions"
          })
        ]
      }

      mixed_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user([
              ContentPart.image_url("https://example.com/render.php?id=99")
            ]),
            mixed_assistant,
            Context.user("Continue")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input", "content" => [%{"type" => "image"}]},
               %{"type" => "custom_step", "v" => 1},
               %{"type" => "user_input"}
             ] = mixed_body["input"]

      foreign_handoff_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([
            Context.user("First"),
            %Message{
              role: :assistant,
              content: [ContentPart.provider_block(:anthropic, %{"type" => "thinking"}, %{})]
            },
            Context.user("Second")
          ]),
          google_api: :interactions
        )

      assert [
               %{"type" => "user_input"},
               %{"type" => "model_output", "content" => [%{"type" => "text", "text" => ""}]},
               %{"type" => "user_input"}
             ] = foreign_handoff_body["input"]
    end
  end

  describe "schema, tools, and option helper edge cases" do
    test "encodes :object TextResponseFormat without $schema or 4096 fallback and respects thinking_summaries" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true, doc: "Person name"],
          score: [type: :integer]
        )

      uncatalogued_model = LLMDB.Model.new!(%{id: "gemini-4-custom", provider: :google})

      {:ok, obj_req} =
        Google.prepare_request(:object, uncatalogued_model, "Extract entity",
          api_key: @api_key,
          google_api: :interactions,
          compiled_schema: compiled,
          reasoning_effort: :low
        )

      obj_body = Google.encode_body(obj_req).options[:json]

      assert obj_body["response_format"]["type"] == "text"
      assert obj_body["response_format"]["mime_type"] == "application/json"
      refute Map.has_key?(obj_body["response_format"]["schema"], "$schema")
      assert obj_body["generation_config"]["thinking_level"] == "low"
      assert obj_body["generation_config"]["thinking_summaries"] == "none"
      refute Map.has_key?(obj_body["generation_config"], "max_output_tokens")

      {:ok, explicit_req} =
        Google.prepare_request(:object, @model_id, "Extract entity",
          api_key: @api_key,
          google_api: :interactions,
          compiled_schema: compiled,
          max_tokens: 50,
          provider_options: [google_include_thoughts: false]
        )

      explicit_body = Google.encode_body(explicit_req).options[:json]
      assert explicit_body["generation_config"]["thinking_summaries"] == "none"
      assert explicit_body["generation_config"]["max_output_tokens"] == 50

      {:ok, dollar_schema} =
        ReqLLM.Schema.compile("$schema": [type: :string, required: true], name: [type: :string])

      schema_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Extract")]),
          google_api: :interactions,
          operation: :object,
          compiled_schema: dollar_schema
        )

      refute Map.has_key?(schema_body["response_format"]["schema"], "$schema")

      assert Map.has_key?(
               schema_body["response_format"]["schema"]["properties"],
               "$schema"
             )

      explicit_fmt_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Return JSON")]),
          google_api: :interactions,
          response_format: %{
            type: "text",
            mime_type: "application/json",
            schema: %{
              "$schema" => "https://json-schema.org/draft/2020-12/schema",
              "type" => "object",
              "properties" => %{"$schema" => %{"type" => "string"}}
            }
          }
        )

      refute Map.has_key?(explicit_fmt_body["response_format"]["schema"], "$schema")

      assert explicit_fmt_body["response_format"]["schema"]["properties"]["$schema"] == %{
               "type" => "string"
             }
    end

    test "encodes keyword response_format and unwraps json_object decoding" do
      {:ok, model} = ReqLLM.model(@model_id)

      kw_json_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("JSON")]),
          google_api: :interactions,
          response_format: [type: "json_object"]
        )

      assert kw_json_body["response_format"] == %{
               "type" => "text",
               "mime_type" => "application/json"
             }

      kw_schema_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Schema JSON")]),
          google_api: :interactions,
          response_format: [
            type: :json_schema,
            json_schema: [
              schema: [
                type: "object",
                properties: [ok: [type: "boolean"]],
                required: []
              ]
            ]
          ]
        )

      assert kw_schema_body["response_format"] == %{
               "type" => "text",
               "mime_type" => "application/json",
               "schema" => %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => []
               }
             }

      assert {:ok, unwrapped_kw_resp} =
               InteractionsAPI.decode_interaction_body(
                 %{
                   "id" => "int_kw_fmt",
                   "status" => "completed",
                   "steps" => [
                     %{
                       "type" => "model_output",
                       "content" => [%{"type" => "text", "text" => ~s({"ok":true})}]
                     }
                   ]
                 },
                 model,
                 Context.new([Context.user("JSON")]),
                 response_format: [type: "json_object"]
               )

      assert unwrapped_kw_resp.object == %{"ok" => true}
    end

    test "encodes lowercase function tools, built-in tools, deduplication, and code execution toggles" do
      fn_tool =
        Tool.new!(
          name: "get_quote",
          description: "Get stock quote",
          parameter_schema: [symbol: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      {:ok, req} =
        Google.prepare_request(:chat, @model_id, "Check NVDA and browse web",
          api_key: @api_key,
          google_api: :interactions,
          tools: [
            fn_tool,
            %{type: "google_search", search_types: ["web_search"]},
            %{type: "computer_use", environment: "browser"}
          ],
          tool_choice: %{name: "get_quote"},
          provider_options: [
            google_search_types: ["web_search", "image_search"],
            google_code_execution: true,
            google_url_context: true,
            google_file_search: %{file_search_store_names: ["fileSearchStores/store-1"]},
            google_mcp_servers: [%{name: "linear", url: "https://mcp.example.com"}]
          ]
        )

      body = Google.encode_body(req).options[:json]

      assert body["generation_config"]["tool_choice"] == %{
               "allowed_tools" => %{"mode" => "any", "tools" => ["get_quote"]}
             }

      tools = body["tools"]
      assert Enum.any?(tools, &(&1["type"] == "function" and &1["name"] == "get_quote"))
      refute Enum.any?(tools, &Map.has_key?(&1["parameters"] || %{}, "$schema"))
      assert Enum.count(tools, &(&1["type"] == "google_search")) == 1
      assert %{"type" => "computer_use", "environment" => "browser"} in tools
      assert %{"type" => "code_execution"} in tools
      assert %{"type" => "url_context"} in tools

      assert %{"type" => "file_search", "file_search_store_names" => ["fileSearchStores/store-1"]} in tools

      assert %{"type" => "mcp_server", "name" => "linear", "url" => "https://mcp.example.com"} in tools

      disabled_code_exec_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Hi")]),
          google_api: :interactions,
          provider_options: [google_code_execution: %{enable: false}]
        )

      refute Map.has_key?(disabled_code_exec_body, "tools")

      custom_code_exec_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Hi")]),
          google_api: :interactions,
          provider_options: [google_code_execution: %{enable: true, timeout_seconds: 15}]
        )

      assert custom_code_exec_body["tools"] == [
               %{"type" => "code_execution", "timeout_seconds" => 15}
             ]
    end

    test "drops nil tool parameters, deduplicates mcp_server tools, and validates tool/tool_choice inputs" do
      nil_param_tool = %Tool{
        name: "ping",
        description: "Ping",
        parameter_schema: nil,
        callback: fn _ -> {:ok, "pong"} end
      }

      tool_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user([ContentPart.text("")])]),
          google_api: :interactions,
          tools: [
            nil_param_tool,
            %{type: "computer_use", display_width: 800},
            %{type: "mcp_server", name: "docs", url: "https://mcp.example.com"}
          ],
          google_mcp_servers: [
            %{name: "docs", url: "https://duplicate.example.com"},
            %{name: "other", url: "https://other.example.com"}
          ]
        )

      assert [
               %{"type" => "function", "name" => "ping"} = encoded_ping,
               %{"type" => "computer_use"},
               %{"type" => "mcp_server", "name" => "docs", "url" => "https://mcp.example.com"},
               %{"type" => "mcp_server", "name" => "other"}
             ] = tool_body["tools"]

      refute Map.has_key?(encoded_ping, "parameters")

      kw_choice_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Use tool")]),
          google_api: :interactions,
          tool_choice: [name: :lookup]
        )

      assert kw_choice_body["generation_config"]["tool_choice"] == %{
               "allowed_tools" => %{"mode" => "any", "tools" => ["lookup"]}
             }

      top_name_choice_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Fallback top_name")]),
          google_api: :interactions,
          tool_choice: %{function: "get_weather", name: "get_weather"}
        )

      assert top_name_choice_body["generation_config"]["tool_choice"] == %{
               "allowed_tools" => %{"mode" => "any", "tools" => ["get_weather"]}
             }

      nested_kw_choice_body =
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Nested kw tool_choice")]),
          google_api: :interactions,
          tool_choice: [type: "function", function: [name: :get_weather]]
        )

      assert nested_kw_choice_body["generation_config"]["tool_choice"] == %{
               "allowed_tools" => %{"mode" => "any", "tools" => ["get_weather"]}
             }

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Bad tool choice")]),
          google_api: :interactions,
          tool_choice: :unsupported_mode
        )
      end

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Bad function tool_choice")]),
          google_api: :interactions,
          tool_choice: %{type: "function", function: "get_weather"}
        )
      end

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Bad tool")]),
          google_api: :interactions,
          tools: [%{"type" => "function", "name" => ""}]
        )
      end

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(
          @model_id,
          Context.new([Context.user("Non-map tool")]),
          google_api: :interactions,
          tools: [:invalid_tool]
        )
      end
    end

    test "handles reused call_id across turns, parallel partial tool results, and explicit_option?/drop_default_include_thoughts" do
      {:ok, model} = ReqLLM.model(@model_id)

      {:ok, reused_id_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_reuse_id",
            "status" => "completed",
            "steps" => [
              %{"type" => "user_input", "content" => "Turn 1"},
              %{
                "type" => "function_call",
                "id" => "call_0",
                "name" => "lookup",
                "arguments" => %{}
              },
              %{
                "type" => "function_result",
                "call_id" => "call_0",
                "name" => "lookup",
                "result" => "done"
              },
              %{"type" => "user_input", "content" => "Turn 2"},
              %{
                "type" => "function_call",
                "id" => "call_0",
                "name" => "lookup",
                "arguments" => %{"q" => "next"}
              }
            ]
          },
          model,
          Context.new([Context.user("Turn 2")])
        )

      assert reused_id_resp.finish_reason == :tool_calls
      assert [%{id: "call_0"}] = ReqLLM.Response.tool_calls(reused_id_resp)

      {:ok, partial_parallel_resp} =
        InteractionsAPI.decode_interaction_body(
          %{
            "id" => "int_partial_parallel",
            "status" => "requires_action",
            "steps" => [
              %{"type" => "user_input", "content" => "Run two"},
              %{
                "type" => "function_call",
                "id" => "fc_1",
                "name" => "fn_a",
                "arguments" => %{}
              },
              %{
                "type" => "function_call",
                "id" => "fc_2",
                "name" => "fn_b",
                "arguments" => %{}
              },
              %{
                "type" => "function_result",
                "call_id" => "fc_1",
                "name" => "fn_a",
                "result" => "ok"
              }
            ]
          },
          model,
          Context.new([Context.user("Run two")])
        )

      assert partial_parallel_resp.finish_reason == :tool_calls

      assert Enum.map(ReqLLM.Response.tool_calls(partial_parallel_resp), & &1.id) == ["fc_2"]

      assert Enum.any?(
               InteractionsAPI.verified_interactions_steps(partial_parallel_resp.message),
               &(&1["id"] == "fc_1")
             )

      refute InteractionsAPI.explicit_option?(
               [google_include_thoughts: nil],
               :google_include_thoughts
             )

      refute InteractionsAPI.explicit_option?(
               %{provider_options: %{"google_include_thoughts" => nil}},
               :google_include_thoughts
             )

      dropped_map_opts =
        InteractionsAPI.drop_default_include_thoughts(
          [provider_options: %{store: true, google_include_thoughts: false}],
          false
        )

      assert dropped_map_opts[:provider_options] == %{store: true}
    end
  end
end
