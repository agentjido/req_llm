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

  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
