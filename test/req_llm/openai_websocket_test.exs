defmodule ReqLLM.OpenAIWebSocketTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Error.API.Timeout
  alias ReqLLM.OpenAI.Realtime
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
                     %{"type" => "response.create", "response" => request}}

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
