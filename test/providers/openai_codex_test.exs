defmodule ReqLLM.Providers.OpenAICodexTest do
  @moduledoc """
  Provider-level tests for the OpenAI Codex backend implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.OpenAICodex

  alias ReqLLM.Providers.OpenAICodex

  describe "provider contract" do
    test "provider identity and configuration" do
      assert OpenAICodex.provider_id() == :openai_codex
      assert OpenAICodex.oauth_provider_id() == "openai-codex"
      assert OpenAICodex.base_url() == "https://chatgpt.com/backend-api"
    end
  end

  describe "request preparation" do
    test "prepare_request routes to codex responses endpoint with oauth headers" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Summarize BHP",
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_123"),
            codex_originator: "pi"
          ]
        )

      assert request.url.path == "/codex/responses"
      assert request.headers["authorization"] == ["Bearer #{jwt_with_account_id("acct_123")}"]
      assert request.headers["chatgpt-account-id"] == ["acct_123"]
      assert request.headers["originator"] == ["pi"]
      refute Map.has_key?(request.headers, "x-openai-internal-codex-responses-lite")
    end

    test "prepare_request automatically enables Responses Lite from model metadata" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.6-sol")

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Summarize BHP",
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_lite")
          ]
        )

      assert request.headers["x-openai-internal-codex-responses-lite"] == ["true"]
    end

    test "prepare_request preserves max reasoning effort for GPT-5.6" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.6-sol")

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Solve carefully",
          reasoning_effort: :max,
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_max")
          ]
        )

      encoded_request = OpenAICodex.encode_body(request)
      body = Jason.decode!(encoded_request.body)

      assert body["reasoning"]["effort"] == "max"
    end

    test "prepare_request loads oauth_file without explicit auth_mode" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
      path = oauth_file_path("prepare")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_file_prepare"),
          "refresh" => "refresh-token-prepare",
          "expires" => future_expiry(),
          "accountId" => "acct_file_prepare"
        }
      })

      {:ok, request} =
        OpenAICodex.prepare_request(:chat, model, "Summarize BHP",
          provider_options: [oauth_file: path]
        )

      assert request.headers["authorization"] == [
               "Bearer #{jwt_with_account_id("acct_file_prepare")}"
             ]

      assert request.headers["chatgpt-account-id"] == ["acct_file_prepare"]
    end

    test "prepare_request rejects api_key auth mode" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        OpenAICodex.prepare_request(:chat, model, "Hello",
          provider_options: [auth_mode: :api_key]
        )
      end
    end

    test "attach rejects anonymous auth modes" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      for mode <- [:none, "none"] do
        assert_raise ReqLLM.Error.Invalid.Parameter, ~r/requires.*:oauth/, fn ->
          OpenAICodex.attach(Req.new(), model, provider_options: [auth_mode: mode])
        end
      end
    end
  end

  describe "session and prompt cache identity" do
    test "preserves explicit cache and hyphenated session headers across transports" do
      for model_id <- ["gpt-5.3-codex-spark", "gpt-5.6-sol", "gpt-6-astra"] do
        {:ok, model} = ReqLLM.model("openai_codex:#{model_id}")
        context = ReqLLM.context([ReqLLM.Context.user("Hello")])

        opts = [
          provider_options: [
            access_token: jwt_with_account_id("acct_cache"),
            session_id: "session-123",
            thread_id: "thread-456",
            prompt_cache_key: "cache-override"
          ]
        ]

        {:ok, buffered} = OpenAICodex.prepare_request(:chat, model, context, opts)
        assert buffered.headers["x-client-request-id"] == ["thread-456"]
        assert buffered.headers["session-id"] == ["session-123"]
        assert buffered.headers["thread-id"] == ["thread-456"]
        refute Map.has_key?(buffered.headers, "session_id")

        assert Jason.decode!(OpenAICodex.encode_body(buffered).body)["prompt_cache_key"] ==
                 "cache-override"

        {:ok, sse} = OpenAICodex.attach_stream(model, context, opts, nil)
        assert {"x-client-request-id", "thread-456"} in sse.headers
        assert {"session-id", "session-123"} in sse.headers
        assert {"thread-id", "thread-456"} in sse.headers
        assert Jason.decode!(sse.body)["prompt_cache_key"] == "cache-override"

        {:ok, websocket} = OpenAICodex.attach_websocket_stream(model, context, opts)
        assert {"x-client-request-id", "thread-456"} in websocket.headers
        assert {"session-id", "session-123"} in websocket.headers
        assert {"thread-id", "thread-456"} in websocket.headers
        refute List.keymember?(websocket.headers, "session_id", 0)
        assert websocket.canonical_json["prompt_cache_key"] == "cache-override"
      end
    end

    test "defaults the cache key to the caller's session across repeated requests and transports" do
      for model_id <- ["gpt-5.3-codex-spark", "gpt-5.6-sol", "gpt-6-astra"] do
        {:ok, model} = ReqLLM.model("openai_codex:#{model_id}")
        context = ReqLLM.context([ReqLLM.Context.user("Hello")])

        opts = [
          provider_options: [
            access_token: jwt_with_account_id("acct_cache"),
            session_id: "session-123"
          ]
        ]

        for _ <- 1..2 do
          {:ok, buffered} = OpenAICodex.prepare_request(:chat, model, context, opts)
          assert buffered.headers["session-id"] == ["session-123"]

          assert Jason.decode!(OpenAICodex.encode_body(buffered).body)["prompt_cache_key"] ==
                   "session-123"

          refute Map.has_key?(buffered.headers, "x-client-request-id")
          refute Map.has_key?(buffered.headers, "thread-id")

          {:ok, sse} = OpenAICodex.attach_stream(model, context, opts, nil)
          assert {"session-id", "session-123"} in sse.headers
          assert Jason.decode!(sse.body)["prompt_cache_key"] == "session-123"
          refute List.keymember?(sse.headers, "x-client-request-id", 0)
          refute List.keymember?(sse.headers, "thread-id", 0)

          {:ok, websocket} = OpenAICodex.attach_websocket_stream(model, context, opts)
          assert {"session-id", "session-123"} in websocket.headers
          assert websocket.canonical_json["prompt_cache_key"] == "session-123"
          refute List.keymember?(websocket.headers, "thread-id", 0)

          assert {"x-client-request-id", request_id} =
                   List.keyfind(websocket.headers, "x-client-request-id", 0)

          refute request_id == "session-123"
        end
      end
    end

    test "does not invent a session or cache identity on any transport when none is supplied" do
      for model_id <- ["gpt-5.3-codex-spark", "gpt-5.6-sol", "gpt-6-astra"] do
        {:ok, model} = ReqLLM.model("openai_codex:#{model_id}")
        context = ReqLLM.context([ReqLLM.Context.user("Hello")])
        opts = [provider_options: [access_token: jwt_with_account_id("acct_cache")]]

        {:ok, buffered} = OpenAICodex.prepare_request(:chat, model, context, opts)

        refute Map.has_key?(
                 Jason.decode!(OpenAICodex.encode_body(buffered).body),
                 "prompt_cache_key"
               )

        {:ok, sse} = OpenAICodex.attach_stream(model, context, opts, nil)
        refute Map.has_key?(Jason.decode!(sse.body), "prompt_cache_key")

        {:ok, websocket} = OpenAICodex.attach_websocket_stream(model, context, opts)
        refute Map.has_key?(websocket.canonical_json, "prompt_cache_key")

        for header <- ["session-id", "thread-id", "session_id", "thread_id"] do
          refute Map.has_key?(buffered.headers, header)
          refute List.keymember?(sse.headers, header, 0)
          refute List.keymember?(websocket.headers, header, 0)
        end
      end
    end
  end

  describe "canonical turn attribution" do
    test "projects caller-owned turn metadata on all transports and every create frame" do
      for model_id <- ["gpt-5.3-codex-spark", "gpt-5.6-sol", "gpt-6-astra"] do
        model = ReqLLM.model!("openai_codex:#{model_id}")
        context = ReqLLM.context([ReqLLM.Context.user("Hello")])

        for turn_id <- ["turn-1", "turn-1", "turn-2"] do
          metadata = %{
            turn_id: turn_id,
            window_id: "window-1",
            request_kind: "turn",
            turn_started_at_unix_ms: 1_800_000_000_000,
            installation_id: "installation-1"
          }

          opts = [
            provider_options: [
              openai_codex: [
                access_token: jwt_with_account_id("acct_turn"),
                session_id: "session-1",
                thread_id: "thread-1",
                prompt_cache_key: "independent-cache",
                codex_turn_metadata: metadata
              ]
            ]
          ]

          {:ok, buffered} = OpenAICodex.prepare_request(:chat, model, context, opts)
          {:ok, sse} = OpenAICodex.attach_stream(model, context, opts, nil)
          {:ok, websocket} = OpenAICodex.attach_websocket_stream(model, context, opts)
          [frame] = websocket.initial_messages

          for {headers, body} <- [
                {buffered.headers, Jason.decode!(OpenAICodex.encode_body(buffered).body)},
                {Map.new(sse.headers), Jason.decode!(sse.body)},
                {Map.new(websocket.headers), Jason.decode!(frame)}
              ] do
            client = body["client_metadata"]
            assert client["session_id"] == "session-1"
            assert client["thread_id"] == "thread-1"
            assert client["turn_id"] == turn_id
            assert client["x-codex-window-id"] == "window-1"
            assert client["x-codex-installation-id"] == "installation-1"

            assert List.wrap(headers["x-codex-turn-metadata"]) == [
                     client["x-codex-turn-metadata"]
                   ]

            assert Jason.decode!(client["x-codex-turn-metadata"]) ==
                     Map.merge(
                       Map.new(metadata, fn {k, v} -> {Atom.to_string(k), v} end),
                       %{"session_id" => "session-1", "thread_id" => "thread-1"}
                     )

            assert body["prompt_cache_key"] == "independent-cache"
          end
        end
      end
    end

    test "does not invent attribution when the caller supplies only a session" do
      model = ReqLLM.model!("openai_codex:gpt-6-astra")
      context = ReqLLM.context([ReqLLM.Context.user("Hello")])

      opts = [
        provider_options: [access_token: jwt_with_account_id("acct_turn"), session_id: "session"]
      ]

      {:ok, websocket} = OpenAICodex.attach_websocket_stream(model, context, opts)
      refute Map.has_key?(websocket.canonical_json, "client_metadata")
      refute List.keymember?(websocket.headers, "x-codex-turn-metadata", 0)
    end
  end

  describe "attach_stream/4" do
    test "builds SSE request against codex backend with combined instructions" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      context =
        ReqLLM.context([
          ReqLLM.Context.system("You are a mining analyst."),
          ReqLLM.Context.user("Tell me about FMG"),
          ReqLLM.Context.system("Use bullet points.")
        ])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_stream")
            ]
          ],
          nil
        )

      assert request.scheme == :https
      assert request.host == "chatgpt.com"
      assert request.path == "/backend-api/codex/responses"
      assert {"accept", "text/event-stream"} in request.headers
      assert {"openai-beta", "responses=experimental"} in request.headers
      refute {"x-openai-internal-codex-responses-lite", "true"} in request.headers

      body = ReqLLM.Test.Helpers.json_body(request)

      assert body["instructions"] == "You are a mining analyst.\n\nUse bullet points."
      assert body["model"] == "gpt-5.3-codex-spark"
      assert body["store"] == false
      assert body["include"] == ["reasoning.encrypted_content"]
      assert body["text"] == %{"verbosity" => "medium"}
      refute Map.has_key?(body, "max_output_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
      assert Enum.all?(body["input"], &(&1["role"] != "system"))
    end

    test "adds Responses Lite to SSE requests for matching models" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.6-sol")
      context = ReqLLM.context([ReqLLM.Context.user("Say hi")])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_lite_stream")
            ]
          ],
          nil
        )

      assert {"x-openai-internal-codex-responses-lite", "true"} in request.headers

      body = ReqLLM.Test.Helpers.json_body(request)

      refute Map.has_key?(body, "instructions")
      refute Map.has_key?(body, "tools")
      assert body["parallel_tool_calls"] == false
      assert body["reasoning"]["context"] == "all_turns"
      assert [%{"type" => "additional_tools", "role" => "developer"} | _input] = body["input"]
    end

    test "normalizes Responses Lite tools and images after shared Responses encoding" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.6-sol")

      local_tool =
        ReqLLM.Tool.new!(
          name: "lookup",
          description: "Look up a value",
          parameter_schema: [value: [type: :string, required: true]],
          callback: fn args -> {:ok, args} end
        )

      context =
        ReqLLM.context([
          ReqLLM.Context.user([
            ReqLLM.Message.ContentPart.image_url("https://example.com/image.png"),
            ReqLLM.Message.ContentPart.image("png", "image/png")
          ])
        ])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            tools: [
              %{"type" => "web_search"},
              %{"type" => "image_generation"},
              local_tool
            ],
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_lite_contract")
            ]
          ],
          nil
        )

      body = ReqLLM.Test.Helpers.json_body(request)
      [additional_tools, user_message] = body["input"]

      assert [%{"type" => "function", "name" => "lookup"}] = additional_tools["tools"]

      assert [omission, data_image] = user_message["content"]

      assert omission == %{
               "type" => "input_text",
               "text" => "image content omitted because remote image URLs are not supported"
             }

      assert data_image["type"] == "input_image"
      assert String.starts_with?(data_image["image_url"], "data:image/png;base64,")
      refute Map.has_key?(data_image, "detail")
    end

    test "builds websocket request with codex websocket beta" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      {:ok, config} =
        OpenAICodex.attach_websocket_stream(
          model,
          ReqLLM.context([
            ReqLLM.Context.assistant("Previous answer", metadata: %{response_id: "resp_ws_789"}),
            ReqLLM.Context.user("Say hi")
          ]),
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_ws"),
            session_id: "req_ws",
            thread_id: "thread_ws"
          ]
        )

      assert config.url == "wss://chatgpt.com/backend-api/codex/responses"
      assert config.fallback_transport == :http
      assert {"openai-beta", "responses_websockets=2026-02-06"} in config.headers
      assert {"session-id", "req_ws"} in config.headers
      assert {"thread-id", "thread_ws"} in config.headers
      assert {"x-client-request-id", "thread_ws"} in config.headers
      refute {"x-openai-internal-codex-responses-lite", "true"} in config.headers
      refute Enum.any?(config.headers, &(elem(&1, 0) == "content-type"))

      payload = config.initial_messages |> hd() |> Jason.decode!()

      assert payload["type"] == "response.create"
      assert payload["model"] == "gpt-5.3-codex-spark"
      assert payload["store"] == false
      assert payload["stream"] == true
      assert payload["previous_response_id"] == "resp_ws_789"
      refute Map.has_key?(payload, "max_completion_tokens")
      refute Map.has_key?(payload, "response")
    end

    test "adds Responses Lite to websocket requests for matching models" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.6-sol")

      {:ok, config} =
        OpenAICodex.attach_websocket_stream(
          model,
          ReqLLM.context([ReqLLM.Context.user("Say hi")]),
          provider_options: [
            auth_mode: :oauth,
            access_token: jwt_with_account_id("acct_lite_ws")
          ]
        )

      assert {"x-openai-internal-codex-responses-lite", "true"} in config.headers

      payload = config.initial_messages |> hd() |> Jason.decode!()

      refute Map.has_key?(payload, "previous_response_id")
      refute Map.has_key?(payload, "instructions")
      refute Map.has_key?(payload, "tools")
      assert payload["parallel_tool_calls"] == false
      assert payload["reasoning"]["context"] == "all_turns"
      assert [%{"type" => "additional_tools", "role" => "developer"} | _input] = payload["input"]
    end

    test "loads oauth_file without explicit auth_mode for streaming" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
      path = oauth_file_path("stream")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_file_stream"),
          "refresh" => "refresh-token-stream",
          "expires" => future_expiry(),
          "accountId" => "acct_file_stream"
        }
      })

      context = ReqLLM.context([ReqLLM.Context.user("Tell me about FMG")])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [provider_options: [oauth_file: path]],
          nil
        )

      assert {"authorization", "Bearer #{jwt_with_account_id("acct_file_stream")}"} in request.headers
      assert {"chatgpt-account-id", "acct_file_stream"} in request.headers
    end

    test "omits previous_response_id for tool resume flow while keeping store=false" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      assistant =
        ReqLLM.Context.assistant(
          "",
          tool_calls: [{"test", %{a: 1, b: 2}, id: "call_123"}],
          metadata: %{response_id: "resp_prev_123"}
        )

      tool_result = ReqLLM.Context.tool_result("call_123", "test", %{result: "1 + 2"})

      context =
        ReqLLM.context([assistant, tool_result, ReqLLM.Context.user("Use the tool result")])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_resume")
            ]
          ],
          nil
        )

      body = ReqLLM.Test.Helpers.json_body(request)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false

      assert Enum.any?(
               body["input"],
               &(&1["type"] == "function_call_output" and &1["call_id"] == "call_123")
             )
    end

    test "omits previous_response_id from HTTP context metadata while keeping store=false" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      context =
        ReqLLM.context([
          ReqLLM.Context.assistant("Previous answer", metadata: %{response_id: "resp_prev_789"}),
          ReqLLM.Context.user("Follow up")
        ])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_context_resume")
            ]
          ],
          nil
        )

      body = ReqLLM.Test.Helpers.json_body(request)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false
    end

    test "omits previous_response_id for explicit tool_outputs resume while keeping store=false" do
      # Tool-resume turns (those carrying function_call_output items) follow a
      # distinct backend contract that deliberately drops previous_response_id
      # (see #613). That is independent of the store/previous_response_id
      # coupling fixed in ResponsesAPI.build_request_body/4 and is preserved here.
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
      context = ReqLLM.context([ReqLLM.Context.user("Use the provided tool output")])

      {:ok, request} =
        OpenAICodex.attach_stream(
          model,
          context,
          [
            provider_options: [
              auth_mode: :oauth,
              access_token: jwt_with_account_id("acct_manual_resume"),
              previous_response_id: "resp_prev_manual",
              tool_outputs: [[call_id: "call_456", output: %{result: "manual"}]]
            ]
          ],
          nil
        )

      body = ReqLLM.Test.Helpers.json_body(request)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false

      assert Enum.any?(
               body["input"],
               &(&1["type"] == "function_call_output" and &1["call_id"] == "call_456")
             )
    end
  end

  describe "decode_stream_event/3" do
    test "normalizes response.done into a terminal response.completed chunk" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      event = %{
        data: %{
          "type" => "response.done",
          "response" => %{
            "id" => "resp_123",
            "status" => "completed",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
          }
        }
      }

      {chunks, _state} = OpenAICodex.decode_stream_event(event, model, nil)

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] = chunks
      assert metadata[:terminal?] == true
      assert metadata[:response_id] == "resp_123"
      assert metadata[:finish_reason] == :stop
    end

    test "decodes response.failed into a terminal error chunk" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      event = %{
        data: %{
          "type" => "response.failed",
          "response" => %{
            "error" => %{"code" => "server_error", "message" => "Codex response failed"}
          }
        }
      }

      assert {[%ReqLLM.StreamChunk{type: :meta, metadata: metadata}], _state} =
               OpenAICodex.decode_stream_event(event, model, nil)

      assert metadata.terminal? == true
      assert metadata.finish_reason == :error
      assert metadata.error == "Codex response failed"
      assert metadata.error_code == "server_error"
    end

    test "decodes nested error details into a terminal error chunk" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      event = %{
        event: "error",
        data: %{
          "type" => "error",
          "error" => %{
            "code" => "cyber_policy",
            "type" => "invalid_request",
            "message" => "This content was flagged for possible cybersecurity risk."
          }
        }
      }

      assert {[%ReqLLM.StreamChunk{type: :meta, metadata: metadata}], _state} =
               OpenAICodex.decode_stream_event(event, model, nil)

      assert metadata.terminal? == true
      assert metadata.finish_reason == :error
      assert metadata.error == "This content was flagged for possible cybersecurity risk."
      assert metadata.error_code == "cyber_policy"
    end

    test "keeps StreamServer alive when the provider returns an error event" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      server = start_supervised!({ReqLLM.StreamServer, provider_mod: OpenAICodex, model: model})

      payload = %{
        "type" => "error",
        "error" => %{
          "code" => "cyber_policy",
          "type" => "invalid_request",
          "message" => "This content was flagged for possible cybersecurity risk."
        }
      }

      assert :ok =
               ReqLLM.StreamServer.http_event(
                 server,
                 {:data, "event: error\ndata: #{Jason.encode!(payload)}\n\n"}
               )

      assert Process.alive?(server)

      assert {:ok, %ReqLLM.StreamChunk{type: :meta, metadata: metadata}} =
               ReqLLM.StreamServer.next(server)

      assert metadata.terminal? == true
      assert metadata.finish_reason == :error
      assert metadata.error == "This content was flagged for possible cybersecurity risk."
      assert metadata.error_code == "cyber_policy"
    end
  end

  describe "decode_response/1" do
    test "builds a normal response from a full SSE body" do
      {:ok, model} = ReqLLM.model("openai_codex:gpt-5.3-codex-spark")

      req = %Req.Request{
        options: [
          model: model.id,
          context: ReqLLM.context("Reply with exactly OK.")
        ]
      }

      body = """
      data: {"type":"response.output_text.delta","delta":"OK"}

      data: {"type":"response.done","response":{"id":"resp_live","status":"completed","usage":{"input_tokens":4,"output_tokens":1,"total_tokens":5}}}

      """

      resp = %Req.Response{status: 200, body: body}

      {_, decoded} = OpenAICodex.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded.body
      assert ReqLLM.Response.text(decoded.body) == "OK"
      assert decoded.body.finish_reason == :stop
      assert decoded.body.usage[:input_tokens] == 4
    end
  end

  describe "reasoning replay across transports" do
    for transport <- [:buffered, :sse, :websocket] do
      @replay_transport transport

      test "#{transport} replays decoded Codex reasoning before the tool call and result" do
        for model_id <- ["gpt-5.3-codex-spark", "gpt-6.1-sol"] do
          model = ReqLLM.model!("openai_codex:#{model_id}")

          request = %Req.Request{
            options: %{model: model.id, context: ReqLLM.context("Add 2 and 3")}
          }

          reasoning = codex_reasoning_item()
          call = codex_function_call_item()

          event = %{
            "type" => "response.done",
            "response" => %{
              "id" => "resp_reasoning",
              "status" => "completed",
              "output" => [reasoning, call],
              "usage" => %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
            }
          }

          call_event = %{
            "type" => "response.output_item.done",
            "output_index" => 1,
            "item" => call
          }

          sse =
            "data: #{Jason.encode!(call_event)}\n\ndata: #{Jason.encode!(event)}\n\ndata: [DONE]\n\n"

          {_, decoded} =
            OpenAICodex.decode_response({request, %Req.Response{status: 200, body: sse}})

          response = decoded.body
          assert %ReqLLM.Response{} = response
          assert [%{id: "call_add"}] = response.message.tool_calls

          assert [%{provider: :openai_codex, signature: "codex-encrypted"}] =
                   response.message.reasoning_details

          context =
            ReqLLM.Context.append(
              response.context,
              ReqLLM.Context.tool_result("call_add", "add", "5")
            )

          body = codex_replay_body(@replay_transport, model, context)
          assert body["store"] == false
          assert body["include"] == ["reasoning.encrypted_content"]
          refute Map.has_key?(body, "previous_response_id")

          items =
            Enum.filter(
              body["input"],
              &(&1["type"] in ["reasoning", "function_call", "function_call_output"])
            )

          assert [replayed_reasoning, replayed_call, result] = items
          assert replayed_reasoning == reasoning
          assert replayed_call["call_id"] == "call_add"
          assert replayed_call["name"] == "add"
          assert Jason.decode!(replayed_call["arguments"]) == %{"a" => 2, "b" => 3}

          assert result == %{
                   "type" => "function_call_output",
                   "call_id" => "call_add",
                   "output" => "5"
                 }
        end
      end

      test "#{transport} preserves Codex output replay items without duplicating them" do
        model = ReqLLM.model!("openai_codex:gpt-5.3-codex-spark")
        items = [codex_reasoning_item(), codex_function_call_item()]

        assistant =
          ReqLLM.Context.assistant("",
            metadata: %{
              response_id: "resp_reasoning",
              responses_replay: %{provider: :openai_codex, items: items}
            }
          )

        context = ReqLLM.context([assistant, ReqLLM.Context.tool_result("call_add", "add", "5")])
        body = codex_replay_body(@replay_transport, model, context)
        assert Enum.take(body["input"], 2) == items
        assert Enum.count(body["input"], &(&1["type"] == "reasoning")) == 1
        assert Enum.count(body["input"], &(&1["type"] == "function_call")) == 1
        refute Map.has_key?(body, "previous_response_id")
      end

      test "#{transport} does not replay reasoning or raw items from another provider" do
        model = ReqLLM.model!("openai_codex:gpt-5.3-codex-spark")

        for provider <- [:openai, :azure, :meta, :anthropic] do
          detail = %ReqLLM.Message.ReasoningDetails{
            provider: provider,
            format: "openai-responses-v1",
            index: 0,
            encrypted?: true,
            signature: "foreign-encrypted",
            provider_data: %{"id" => "rs_foreign", "type" => "reasoning"}
          }

          assistant =
            ReqLLM.Context.assistant("Previous answer",
              reasoning_details: [detail],
              metadata: %{
                responses_replay: %{provider: provider, items: [codex_reasoning_item()]}
              }
            )

          context = ReqLLM.context([assistant, ReqLLM.Context.user("Continue")])
          body = codex_replay_body(@replay_transport, model, context)
          refute Enum.any?(body["input"], &(&1["type"] == "reasoning"))
          refute Jason.encode!(body) =~ "foreign-encrypted"
          refute Jason.encode!(body) =~ "codex-encrypted"
        end
      end
    end

    test "websocket tool_outputs replay prior reasoning after response chaining is removed" do
      model = ReqLLM.model!("openai_codex:gpt-5.3-codex-spark")

      assistant =
        ReqLLM.Context.assistant("",
          metadata: %{
            response_id: "resp_reasoning",
            responses_replay: %{
              provider: :openai_codex,
              items: [codex_reasoning_item(), codex_function_call_item()]
            }
          }
        )

      body =
        codex_replay_body(:websocket, model, ReqLLM.context([assistant]),
          previous_response_id: "resp_override",
          tool_outputs: [[call_id: "call_add", output: "5"]]
        )

      refute Map.has_key?(body, "previous_response_id")

      assert Enum.map(body["input"], & &1["type"]) == [
               "reasoning",
               "function_call",
               "function_call_output"
             ]

      assert hd(body["input"]) == codex_reasoning_item()
    end

    test "websocket follow-ups without tool results retain response chaining" do
      model = ReqLLM.model!("openai_codex:gpt-5.3-codex-spark")

      assistant =
        ReqLLM.Context.assistant("Previous answer",
          metadata: %{
            response_id: "resp_reasoning",
            responses_replay: %{provider: :openai_codex, items: [codex_reasoning_item()]}
          }
        )

      context = ReqLLM.context([assistant, ReqLLM.Context.user("Continue")])
      body = codex_replay_body(:websocket, model, context)
      assert body["previous_response_id"] == "resp_reasoning"
      refute Enum.any?(body["input"], &(&1["type"] == "reasoning"))
    end

    test "OpenAI requests continue to exclude Codex-owned reasoning and raw replay items" do
      model = ReqLLM.model!("openai_codex:gpt-5.3-codex-spark")

      detail = %ReqLLM.Message.ReasoningDetails{
        provider: :openai_codex,
        format: "openai-responses-v1",
        index: 0,
        encrypted?: true,
        signature: "codex-encrypted",
        provider_data: %{"id" => "rs_codex", "type" => "reasoning"}
      }

      for metadata <- [
            %{},
            %{responses_replay: %{provider: :openai_codex, items: [codex_reasoning_item()]}}
          ] do
        assistant =
          ReqLLM.Context.assistant("Previous answer",
            reasoning_details: [detail],
            metadata: metadata
          )

        context = ReqLLM.context([assistant, ReqLLM.Context.user("Continue")])

        body =
          ReqLLM.Providers.OpenAI.ResponsesAPI.build_request_body(
            context,
            model.id,
            [provider_options: [store: false]],
            nil
          )

        refute Enum.any?(body["input"], &(&1["type"] == "reasoning"))
        refute Jason.encode!(body) =~ "codex-encrypted"
      end
    end
  end

  defp codex_replay_body(transport, model, context, extra_provider_opts \\ []) do
    opts = [
      provider_options:
        Keyword.merge([access_token: jwt_with_account_id("acct_replay")], extra_provider_opts)
    ]

    case transport do
      :buffered ->
        {:ok, request} = OpenAICodex.prepare_request(:chat, model, context, opts)
        request |> OpenAICodex.encode_body() |> ReqLLM.Test.Helpers.json_body()

      :sse ->
        {:ok, request} = OpenAICodex.attach_stream(model, context, opts, nil)
        ReqLLM.Test.Helpers.json_body(request)

      :websocket ->
        {:ok, config} = OpenAICodex.attach_websocket_stream(model, context, opts)
        config.initial_messages |> hd() |> Jason.decode!()
    end
  end

  defp codex_reasoning_item do
    %{
      "id" => "rs_codex",
      "type" => "reasoning",
      "encrypted_content" => "codex-encrypted",
      "summary" => [%{"type" => "summary_text", "text" => "Use the add tool."}]
    }
  end

  defp codex_function_call_item do
    %{
      "id" => "fc_add",
      "type" => "function_call",
      "call_id" => "call_add",
      "name" => "add",
      "arguments" => ~s({"a":2,"b":3})
    }
  end

  defp jwt_with_account_id(account_id) do
    header =
      %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "#{header}.#{payload}.sig"
  end

  defp oauth_file_path(label) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "req_llm_openai_codex_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Path.join(tmp_dir, "oauth.json")
  end

  defp write_oauth_file(path, payload) do
    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp future_expiry do
    System.system_time(:millisecond) + 60_000
  end
end
