defmodule ReqLLM.OpenAIWebSocketTest do
  use ExUnit.Case, async: false

  alias ReqLLM.OpenAI.Realtime

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/v1/responses" do
      WebSockAdapter.upgrade(
        conn,
        ReqLLM.OpenAIWebSocketTest.ResponsesSocket,
        Application.fetch_env!(:req_llm, :openai_websocket_test_pid),
        []
      )
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
      {:ok,
       %{
         test_pid: test_pid,
         mode: Application.get_env(:req_llm, :openai_websocket_test_mode, :immediate),
         retry_counter: Application.get_env(:req_llm, :openai_websocket_retry_counter)
       }}
    end

    @impl true
    def handle_in({message, opts}, state) when is_binary(message) and is_list(opts) do
      payload = Jason.decode!(message)
      send(state.test_pid, {:responses_socket_message, payload})

      case state.mode do
        :delayed ->
          send(state.test_pid, {:responses_socket_waiting, self()})
          {:ok, state}

        :retry_once ->
          case Agent.get_and_update(state.retry_counter, fn count -> {count, count + 1} end) do
            0 -> {:stop, :normal, state}
            _attempt -> {:push, response_messages(), state}
          end

        :partial_then_close ->
          send(self(), :close_after_partial)

          {:push,
           {:text,
            Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "partial"})},
           state}

        :immediate ->
          {:push, response_messages(), state}
      end
    end

    @impl true
    def handle_info(:complete_response, state) do
      {:push, response_messages(), state}
    end

    def handle_info(:close_after_partial, state), do: {:stop, :normal, state}
    def handle_info(_message, state), do: {:ok, state}

    defp response_messages do
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

      [
        {:text, Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello"})},
        {:text, Jason.encode!(response)}
      ]
    end
  end

  defmodule RealtimeSocket do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
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
    def handle_info(_message, test_pid) do
      {:ok, test_pid}
    end
  end

  setup do
    original = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "test-key-12345")
    Application.put_env(:req_llm, :openai_websocket_test_pid, self())
    {:ok, retry_counter} = Agent.start_link(fn -> 0 end)
    Application.put_env(:req_llm, :openai_websocket_retry_counter, retry_counter)

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
      Application.delete_env(:req_llm, :openai_websocket_test_mode)
      Application.delete_env(:req_llm, :openai_websocket_retry_counter)
    end)

    {:ok, base_url: base_url}
  end

  test "stream_text uses OpenAI responses websocket mode when requested", %{base_url: base_url} do
    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Say hello",
        base_url: base_url,
        receive_timeout: 5_000,
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

  test "stream_text allows WebSocket model silence when receive_timeout is infinity", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_test_mode, :delayed)

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Wait for release",
        base_url: base_url,
        connect_timeout: 1_000,
        receive_timeout: :infinity,
        provider_options: [openai_stream_transport: :websocket]
      )

    materializer = Task.async(fn -> ReqLLM.StreamResponse.text(stream_response) end)

    assert_receive {:responses_socket_waiting, socket}
    assert Task.yield(materializer, 50) == nil

    send(socket, :complete_response)
    assert Task.await(materializer) == "Hello"
  end

  test "stream_text retries a transient WebSocket close before provider data", %{
    base_url: base_url
  } do
    Application.put_env(:req_llm, :openai_websocket_test_mode, :retry_once)

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Retry before output",
        base_url: base_url,
        connect_timeout: 1_000,
        receive_timeout: 1_000,
        max_retries: 1,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert ReqLLM.StreamResponse.text(stream_response) == "Hello"
    assert_received {:responses_socket_message, %{"type" => "response.create"}}
    assert_received {:responses_socket_message, %{"type" => "response.create"}}
  end

  test "stream_text does not retry after provider data has started", %{base_url: base_url} do
    Application.put_env(:req_llm, :openai_websocket_test_mode, :partial_then_close)

    {:ok, stream_response} =
      ReqLLM.stream_text(
        "openai:gpt-5",
        "Do not duplicate partial output",
        base_url: base_url,
        connect_timeout: 1_000,
        receive_timeout: 1_000,
        max_retries: 3,
        provider_options: [openai_stream_transport: :websocket]
      )

    assert {:error, %ReqLLM.Error.API.Stream{cause: :closed}} =
             ReqLLM.StreamResponse.process_stream(stream_response)

    assert_received {:responses_socket_message, %{"type" => "response.create"}}
    refute_receive {:responses_socket_message, %{"type" => "response.create"}}, 50
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

  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
