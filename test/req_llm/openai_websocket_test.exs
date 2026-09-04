defmodule ReqLLM.OpenAIWebSocketTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Error.API.Timeout
  alias ReqLLM.OpenAI.Realtime
  alias ReqLLM.OpenAI.Responses
  alias ReqLLM.Streaming.WebSocketSession

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/v1/responses" do
      socket =
        Application.get_env(
          :req_llm,
          :openai_websocket_responses_socket,
          ReqLLM.OpenAIWebSocketTest.ResponsesSocket
        )

      WebSockAdapter.upgrade(
        conn,
        socket,
        Application.fetch_env!(:req_llm, :openai_websocket_test_pid),
        []
      )
    end

    post "/v1/responses" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        Application.fetch_env!(:req_llm, :openai_websocket_test_pid),
        {:responses_http_request, Jason.decode!(body)}
      )

      events = [
        %{"type" => "response.output_text.delta", "delta" => "HTTP fallback"},
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_http_123",
            "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
          }
        }
      ]

      payload = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, payload)
    end

    get "/v1/realtime" do
      WebSockAdapter.upgrade(
        conn,
        ReqLLM.OpenAIWebSocketTest.RealtimeSocket,
        Application.fetch_env!(:req_llm, :openai_websocket_test_pid),
        []
      )
    end
  end

  defmodule ResponsesSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
      {:ok, test_pid}
    end

    @impl true
    def handle_in({message, opts}, test_pid) when is_binary(message) and is_list(opts) do
      payload = Jason.decode!(message)
      send(test_pid, {:responses_socket_message, payload})

      response = %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_test_123",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 4
          }
        }
      }

      messages = [
        {:text, Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello"})},
        {:text, Jason.encode!(response)}
      ]

      {:push, messages, test_pid}
    end

    @impl true
    def handle_info(_message, test_pid) do
      {:ok, test_pid}
    end
  end

  defmodule ControlledResponsesSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
      send(test_pid, {:responses_connected, self()})
      {:ok, test_pid}
    end

    @impl true
    def handle_in({message, _opts}, test_pid) do
      send(test_pid, {:responses_frame, Jason.decode!(message)})
      {:ok, test_pid}
    end

    @impl true
    def handle_info({:emit, event}, test_pid) do
      {:push, {:text, Jason.encode!(event)}, test_pid}
    end

    def handle_info(:disconnect, test_pid), do: {:stop, :normal, {1000, "closed"}, test_pid}
  end

  defmodule MessageTooBigSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_in({message, opts}, test_pid) when is_binary(message) and is_list(opts) do
      send(test_pid, {:responses_oversized_socket_message, Jason.decode!(message)})
      {:stop, :normal, {1009, "message too big"}, test_pid}
    end

    @impl true
    def handle_info(_message, test_pid), do: {:ok, test_pid}
  end

  defmodule MessageTooBigWithoutFallbackProvider do
    def stream_transport(_model, _opts), do: :websocket

    def attach_websocket_stream(model, _context, opts) do
      base_url = Keyword.fetch!(opts, :base_url)
      headers = [{"Authorization", "Bearer test-key-12345"}]
      url = ReqLLM.Providers.OpenAI.WebSocket.responses_url(model, base_url: base_url)

      {:ok,
       %{
         url: url,
         headers: headers,
         initial_messages: [Jason.encode!(%{"type" => "response.create"})],
         canonical_json: %{"type" => "response.create"}
       }}
    end
  end

  defmodule PartialThenMessageTooBigSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_in({_message, opts}, test_pid) when is_list(opts) do
      message = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "partial"})
      {:stop, :normal, {1009, "message too big"}, [{:text, message}], test_pid}
    end

    @impl true
    def handle_info(_message, test_pid), do: {:ok, test_pid}
  end

  defmodule RealtimeSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
      send(test_pid, {:realtime_socket_connected, self()})
      {:ok, test_pid}
    end

    @impl true
    def handle_in({message, opts}, test_pid) when is_binary(message) and is_list(opts) do
      payload = Jason.decode!(message)
      send(test_pid, {:realtime_socket_message, payload})

      response =
        case payload["type"] do
          "session.update" ->
            %{"type" => "session.updated", "session" => payload["session"]}

          "response.create" ->
            %{"type" => "response.created", "response" => %{"id" => "resp_rt_123"}}

          other ->
            %{"type" => "echo", "original_type" => other}
        end

      {:push, {:text, Jason.encode!(response)}, test_pid}
    end

    @impl true
    def handle_info({:emit, payload}, test_pid) do
      {:push, {:text, payload}, test_pid}
    end

    def handle_info(_message, test_pid) do
      {:ok, test_pid}
    end
  end

  setup do
    original = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "test-key-12345")
    Application.put_env(:req_llm, :openai_websocket_test_pid, self())

    port = reserve_port()
    base_url = "http://127.0.0.1:#{port}/v1"
    start_supervised!({Bandit, plug: Router, port: port})

    on_exit(fn ->
      if original do
        System.put_env("OPENAI_API_KEY", original)
      else
        System.delete_env("OPENAI_API_KEY")
      end

      Application.delete_env(:req_llm, :openai_websocket_test_pid)
      Application.delete_env(:req_llm, :openai_websocket_responses_socket)
    end)

    websocket_url = String.replace_prefix(base_url, "http://", "ws://") <> "/realtime"
    {:ok, base_url: base_url, websocket_url: websocket_url}
  end

  test "Responses session reads automatic steering continuations after either terminal event", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_responses_socket, ControlledResponsesSocket)

    for terminal <- ["response.incomplete", "response.completed"] do
      {:ok, session} = Responses.connect("openai:gpt-6-astra", base_url: base_url)
      assert_receive {:responses_connected, socket}

      assert :ok =
               Responses.response_create(session, %{
                 "input" => "Draft a plan",
                 "reasoning" => %{"effort" => "low"}
               })

      assert_receive {:responses_frame,
                      %{
                        "type" => "response.create",
                        "model" => "gpt-6-astra",
                        "input" => "Draft a plan"
                      } = create}

      refute Map.has_key?(create, "response")
      emit_response(socket, "response.created", "resp_1")
      assert {:ok, %{"response" => %{"id" => "resp_1"}}} = Responses.next_event(session)
      assert :ok = Responses.steer(session, "resp_1", "Keep it small")
      assert_receive {:responses_frame, frame}

      assert frame == %{
               "type" => "response.steer",
               "previous_response_id" => "resp_1",
               "input" => "Keep it small"
             }

      accepted = %{
        "type" => "response.steer.accepted",
        "steer" => %{"id" => "steer_1", "previous_response_id" => "resp_1"}
      }

      send(socket, {:emit, accepted})

      emit_response(socket, terminal, "resp_1", %{
        "incomplete_details" => %{"reason" => "steered"}
      })

      emit_response(socket, "response.created", "resp_2")
      emit_response(socket, "response.completed", "resp_2")

      assert {:ok, ^accepted} = Responses.next_event(session)

      assert {:ok, %{"type" => ^terminal, "response" => %{"id" => "resp_1"}}} =
               Responses.next_event(session)

      assert {:ok, %{"type" => "response.created", "response" => %{"id" => "resp_2"}}} =
               Responses.next_event(session)

      assert {:ok, %{"type" => "response.completed", "response" => %{"id" => "resp_2"}}} =
               Responses.next_event(session)

      refute_received {:responses_frame, _}
      assert :ok = Responses.close(session)
    end
  end

  test "Responses session returns pending tool results on the same connection", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_responses_socket, ControlledResponsesSocket)

    {:ok, session} =
      Responses.connect(%{provider: :openai, id: "gpt-6-astra"}, base_url: base_url)

    assert_receive {:responses_connected, socket}
    emit_response(socket, "response.created", "resp_tools")
    assert {:ok, _} = Responses.next_event(session)

    assert :ok =
             Responses.steer(session, "resp_tools", [
               %{"role" => "user", "content" => "Use the result"}
             ])

    assert_receive {:responses_frame, %{"type" => "response.steer"}}

    pending = %{
      "type" => "response.steer.pending",
      "steer" => %{"id" => "steer_pending", "previous_response_id" => "resp_tools"},
      "required_input" => [
        %{"type" => "function_call_output", "call_id" => "call_1", "name" => "lookup"}
      ]
    }

    emit_response(socket, "response.completed", "resp_tools")
    send(socket, {:emit, pending})
    assert {:ok, %{"type" => "response.completed"}} = Responses.next_event(session)
    assert {:ok, ^pending} = Responses.next_event(session)

    continuation = %{
      "previous_response_id" => pending["steer"]["previous_response_id"],
      "input" => [%{"type" => "function_call_output", "call_id" => "call_1", "output" => "Done"}],
      "instructions" => "Use the report",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup",
          "parameters" => %{"type" => "object"},
          "async" => true
        }
      ]
    }

    assert :ok = Responses.response_create(session, continuation)
    assert_receive {:responses_frame, frame}
    assert Map.drop(frame, ["model", "type"]) == continuation
    emit_response(socket, "response.created", "resp_after_tools")
    assert {:ok, %{"response" => %{"id" => "resp_after_tools"}}} = Responses.next_event(session)
    Responses.close(session)
  end

  test "Responses session retains steering failures and does not retry after disconnect", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_responses_socket, ControlledResponsesSocket)
    {:ok, session} = Responses.connect("openai:gpt-6-astra", base_url: base_url)
    assert_receive {:responses_connected, socket}

    failed = %{
      "type" => "response.steer.failed",
      "steer" => %{"id" => "steer_1", "previous_response_id" => "resp_1", "input" => "Update"},
      "error" => %{"code" => "response_not_found"}
    }

    send(socket, {:emit, failed})
    assert {:ok, ^failed} = Responses.next_event(session)
    send(socket, :disconnect)
    assert :halt = Responses.next_event(session)
    assert {:error, _} = Responses.steer(session, "resp_1", "Update")
    refute_received {:responses_connected, _}
    Responses.close(session)
  end

  test "Responses session validates Astra requests and steering before sending", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_responses_socket, ControlledResponsesSocket)
    {:ok, session} = Responses.connect("openai:gpt-6-astra", base_url: base_url)
    assert_receive {:responses_connected, _socket}
    update = %{"type" => "configuration_update", "reasoning" => %{"effort" => "high"}}

    for payload <- [
          %{input: "Hello"},
          %{"stream" => false},
          %{"background" => false},
          %{"response" => %{}},
          %{"model" => "gpt-5"},
          %{"reasoning" => %{"effort" => "none"}},
          %{"top_p" => 0.9},
          %{"input" => [update, update]},
          %{"input" => [update], "truncation" => "auto"},
          %{"input" => [update], "context_management" => [%{"type" => "compaction"}]},
          %{"input" => [update], "multi_agent" => %{"enabled" => true}}
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Responses.response_create(session, payload)
    end

    for input <- [
          "",
          [],
          [%{"role" => "system", "content" => "No"}],
          [%{"type" => "function_call_output", "call_id" => "call_1", "output" => "No"}]
        ] do
      assert {:error, _} = Responses.steer(session, "resp_1", input)
    end

    assert {:error, _} = Responses.steer(session, nil, "Hello")
    other = %{session | model: ReqLLM.model!("openai:gpt-5")}
    assert {:error, _} = Responses.steer(other, "resp_1", "Hello")
    assert {:error, _} = Responses.response_create(other, %{"input" => [update]})
    refute_received {:responses_frame, _}

    assert :ok =
             Responses.response_create(session, %{
               "reasoning" => %{"effort" => "low"},
               "input" => [update, %{"role" => "user", "content" => "Hello"}]
             })

    assert_receive {:responses_frame,
                    %{"reasoning" => %{"effort" => "low"}, "input" => [^update, _]}}

    Responses.close(session)
  end

  defp emit_response(socket, type, id, fields \\ %{}) do
    send(socket, {:emit, %{"type" => type, "response" => Map.put(fields, "id", id)}})
  end

  test "stream_text uses OpenAI responses websocket mode when requested", %{base_url: base_url} do
    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Say hello",
        base_url: base_url,
        receive_timeout: :infinity,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert ReqLLM.StreamResponse.text(stream_response) == "Hello"
    assert ReqLLM.StreamResponse.finish_reason(stream_response) == :stop

    usage = ReqLLM.StreamResponse.usage(stream_response)
    assert usage.input_tokens == 10
    assert usage.output_tokens == 4
    assert usage.total_tokens == 14

    assert_received {:responses_socket_message,
                     %{"type" => "response.create", "model" => "gpt-5"} = request}

    refute Map.has_key?(request, "response")
    refute Map.has_key?(request, "stream")
    assert request["model"] == "gpt-5"
    assert Enum.any?(request["input"], fn item -> item["role"] == "user" end)
  end

  test "falls back from pre-output websocket close 1009 to HTTP/SSE", %{base_url: base_url} do
    Application.put_env(
      :req_llm,
      :openai_websocket_responses_socket,
      MessageTooBigSocket
    )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Say hello",
        base_url: base_url,
        receive_timeout: 5_000,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert ReqLLM.StreamResponse.text(stream_response) == "HTTP fallback"
    assert ReqLLM.StreamResponse.finish_reason(stream_response) == :stop
    assert_received {:responses_oversized_socket_message, %{"type" => "response.create"}}
    assert_received {:responses_http_request, %{"model" => "gpt-5"}}
  end

  test "owned websocket sessions stop after HTTP fallback", %{base_url: base_url} do
    Application.put_env(
      :req_llm,
      :openai_websocket_responses_socket,
      MessageTooBigSocket
    )

    before_pids = websocket_session_pids()

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Say hello",
        base_url: base_url,
        receive_timeout: 5_000,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert ReqLLM.StreamResponse.text(stream_response) == "HTTP fallback"
    assert wait_until(fn -> websocket_session_pids() == before_pids end)
  end

  test "preserves close 1009 when HTTP fallback is not enabled", %{base_url: base_url} do
    Application.put_env(
      :req_llm,
      :openai_websocket_responses_socket,
      MessageTooBigSocket
    )

    {:ok, context} = ReqLLM.Context.normalize("Say hello")
    model = %LLMDB.Model{provider: :test, id: "test", base_url: base_url}

    assert {:ok, stream_response} =
             ReqLLM.Streaming.start_stream(
               MessageTooBigWithoutFallbackProvider,
               model,
               context,
               base_url: base_url,
               connect_timeout: 5_000,
               receive_timeout: 5_000
             )

    assert_raise ReqLLM.Error.API.Stream, ~r/1009/, fn ->
      Enum.to_list(stream_response.stream)
    end

    refute_received {:responses_http_request, _request}
  end

  test "does not replay over HTTP after websocket output", %{base_url: base_url} do
    Application.put_env(
      :req_llm,
      :openai_websocket_responses_socket,
      PartialThenMessageTooBigSocket
    )

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Say hello",
        base_url: base_url,
        receive_timeout: 5_000,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert_raise ReqLLM.Error.API.Stream, ~r/1009/, fn ->
      Enum.to_list(stream_response.stream)
    end

    refute_received {:responses_http_request, _request}
  end

  test "a reusable session keeps HTTP fallback sticky across turns", %{base_url: base_url} do
    Application.put_env(
      :req_llm,
      :openai_websocket_responses_socket,
      MessageTooBigSocket
    )

    {:ok, model} = ReqLLM.model("openai:gpt-5")

    {:ok, session} =
      ReqLLM.Providers.OpenAI.WebSocket.start_responses_session(model,
        base_url: base_url,
        api_key: "test-key-12345"
      )

    for prompt <- ["first", "second"] do
      {:ok, stream_response} =
        ReqLLM.stream_text(
          model,
          prompt,
          base_url: base_url,
          receive_timeout: 5_000,
          provider_options: [
            openai_stream_transport: :websocket,
            openai_websocket_session: session
          ]
        )

      assert ReqLLM.StreamResponse.text(stream_response) == "HTTP fallback"
    end

    assert_received {:responses_oversized_socket_message, %{"type" => "response.create"}}
    refute_received {:responses_oversized_socket_message, %{"type" => "response.create"}}
    assert_received {:responses_http_request, _request}
    assert_received {:responses_http_request, _request}
  end

  test "a dead reusable session does not silently select HTTP" do
    session = spawn(fn -> :ok end)
    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}
    assert reason in [:normal, :noproc]

    opts = [
      provider_options: [
        openai_stream_transport: :websocket,
        openai_websocket_session: session
      ]
    ]

    assert ReqLLM.Providers.OpenAI.stream_transport(nil, opts) == :websocket
    assert ReqLLM.Providers.OpenAICodex.stream_transport(nil, opts) == :websocket
  end

  test "stream_text can reuse caller-owned OpenAI responses websocket sessions", %{
    base_url: base_url
  } do
    {:ok, model} = ReqLLM.model("openai:gpt-5")

    {:ok, session} =
      ReqLLM.Providers.OpenAI.WebSocket.start_responses_session(model,
        base_url: base_url,
        api_key: "test-key-12345"
      )

    try do
      for prompt <- ["Say hello", "Say hello again"] do
        {:ok, stream_response} =
          ReqLLM.stream_text(
            model,
            prompt,
            base_url: base_url,
            receive_timeout: 5_000,
            provider_options: [
              openai_stream_transport: :websocket,
              openai_websocket_session: session
            ]
          )

        assert ReqLLM.StreamResponse.text(stream_response) == "Hello"
        assert Process.alive?(session)
      end
    after
      ReqLLM.Streaming.WebSocketSession.close(session)
    end

    assert_received {:responses_socket_message, %{"type" => "response.create"}}
    assert_received {:responses_socket_message, %{"type" => "response.create"}}
  end

  test "Realtime session can connect, send events, and receive events", %{base_url: base_url} do
    {:ok, session} =
      Realtime.connect("gpt-realtime",
        base_url: base_url,
        receive_timeout: 5_000
      )

    assert :ok =
             Realtime.session_update(session, %{
               "type" => "realtime",
               "instructions" => "Be extra nice today!"
             })

    assert {:ok,
            %{
              "type" => "session.updated",
              "session" => %{"instructions" => "Be extra nice today!"}
            }} =
             Realtime.next_event(session, 5_000)

    assert_received {:realtime_socket_message,
                     %{
                       "type" => "session.update",
                       "session" => %{"instructions" => "Be extra nice today!"}
                     }}

    assert :ok = Realtime.response_create(session, %{"instructions" => "Say hi"})

    assert {:ok, %{"type" => "response.created", "response" => %{"id" => "resp_rt_123"}}} =
             Realtime.next_event(session, 5_000)

    assert_received {:realtime_socket_message,
                     %{"type" => "response.create", "response" => %{"instructions" => "Say hi"}}}

    assert :ok = Realtime.close(session)
  end

  test "a receive timeout does not consume a later WebSocket message", %{
    websocket_url: websocket_url
  } do
    {session, socket} = start_session(websocket_url)

    assert {:error, %Timeout{kind: :receive, timeout: 20}} =
             WebSocketSession.next_message(session, 20)

    receiver = Task.async(fn -> WebSocketSession.next_message(session, :infinity) end)
    send(socket, {:emit, "later-event"})

    assert Task.await(receiver) == {:ok, "later-event"}
  end

  test "a cancelled WebSocket waiter does not consume a later message", %{
    websocket_url: websocket_url
  } do
    {session, socket} = start_session(websocket_url)

    receiver = Task.async(fn -> WebSocketSession.next_message(session, :infinity) end)
    assert :ok = await_websocket_waiter(session, receiver.pid)
    assert Task.shutdown(receiver, :brutal_kill) == nil

    send(socket, {:emit, "later-event"})

    assert WebSocketSession.next_message(session, 1_000) == {:ok, "later-event"}
  end

  test "connection timeout is distinct from receive inactivity" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    accepter =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        Process.sleep(:infinity)
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.exit(accepter, :kill)
      :gen_tcp.close(listener)
    end)

    {:ok, session} =
      WebSocketSession.start_link("ws://127.0.0.1:#{port}/socket", connect_timeout: 30)

    assert {:error, %Timeout{kind: :connect, timeout: 30}} =
             WebSocketSession.await_connected(session, 30)
  end

  test "Realtime session can receive the additive projected event view", %{base_url: base_url} do
    {:ok, session} =
      Realtime.connect("gpt-realtime",
        base_url: base_url,
        receive_timeout: 5_000
      )

    assert :ok = Realtime.response_create(session, %{"instructions" => "Say hi"})

    assert {:ok, projected} = Realtime.next_projected_event(session, payloads: :raw)

    assert projected.type == "response.created"

    assert projected.native == %{
             "type" => "response.created",
             "response" => %{"id" => "resp_rt_123"}
           }

    assert [%ReqLLM.StreamEvent{type: :start, metadata: %{response_id: "resp_rt_123"}}] =
             projected.stream_events

    assert :ok = Realtime.close(session)
  end

  defp start_session(url) do
    {:ok, session} = WebSocketSession.start_link(url, connect_timeout: 1_000)
    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:realtime_socket_connected, socket}
    {session, socket}
  end

  defp await_websocket_waiter(session, receiver_pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_websocket_waiter(session, receiver_pid, deadline)
  end

  defp do_await_websocket_waiter(session, receiver_pid, deadline) do
    waiter_registered? =
      session
      |> :sys.get_state()
      |> Map.fetch!(:waiting_callers)
      |> Enum.any?(fn waiter -> elem(waiter.from, 0) == receiver_pid end)

    if waiter_registered? do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("WebSocket session did not register the waiting caller")
      end

      Process.sleep(5)
      do_await_websocket_waiter(session, receiver_pid, deadline)
    end
  end

  defp websocket_session_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") ==
            {ReqLLM.Streaming.WebSocketSession, :init, 1}

        nil ->
          false
      end
    end)
    |> MapSet.new()
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
