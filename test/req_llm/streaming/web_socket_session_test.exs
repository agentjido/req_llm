defmodule ReqLLM.Streaming.WebSocketSessionTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Error.API.Timeout
  alias ReqLLM.Streaming.WebSocketSession

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/socket" do
      WebSockAdapter.upgrade(
        conn,
        ReqLLM.Streaming.WebSocketSessionTest.Socket,
        Application.fetch_env!(:req_llm, :websocket_session_test_pid),
        []
      )
    end
  end

  defmodule Socket do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
      send(test_pid, {:websocket_connected, self()})
      {:ok, test_pid}
    end

    @impl true
    def handle_in({_message, _opts}, test_pid), do: {:ok, test_pid}

    @impl true
    def handle_info({:emit, payload}, test_pid) do
      {:push, {:text, payload}, test_pid}
    end

    def handle_info(_message, test_pid), do: {:ok, test_pid}
  end

  setup do
    Application.put_env(:req_llm, :websocket_session_test_pid, self())
    port = reserve_port()
    start_supervised!({Bandit, plug: Router, port: port})

    on_exit(fn ->
      Application.delete_env(:req_llm, :websocket_session_test_pid)
    end)

    {:ok, url: "ws://127.0.0.1:#{port}/socket"}
  end

  test "an infinite receive timeout waits until the transport produces data", %{url: url} do
    {:ok, session} = WebSocketSession.start_link(url, connect_timeout: 1_000)
    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:websocket_connected, socket}

    receiver = Task.async(fn -> WebSocketSession.next_message(session, :infinity) end)
    assert Task.yield(receiver, 50) == nil

    send(socket, {:emit, "event"})
    assert Task.await(receiver) == {:ok, "event"}
  end

  test "a finite receive timeout is typed and does not consume a later message", %{url: url} do
    {:ok, session} = WebSocketSession.start_link(url, connect_timeout: 1_000)
    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:websocket_connected, socket}

    assert {:error, %Timeout{kind: :receive, timeout: 20}} =
             WebSocketSession.next_message(session, 20)

    receiver = Task.async(fn -> WebSocketSession.next_message(session, :infinity) end)
    send(socket, {:emit, "later-event"})

    assert Task.await(receiver) == {:ok, "later-event"}
  end

  test "a cancelled infinite waiter does not consume a later message", %{url: url} do
    {:ok, session} = WebSocketSession.start_link(url, connect_timeout: 1_000)
    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:websocket_connected, socket}

    receiver = spawn(fn -> WebSocketSession.next_message(session, :infinity) end)
    assert wait_until(fn -> :sys.get_state(session).waiting_callers != [] end)

    monitor = Process.monitor(receiver)
    Process.exit(receiver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :killed}
    assert wait_until(fn -> :sys.get_state(session).waiting_callers == [] end)

    send(socket, {:emit, "later-event"})

    assert WebSocketSession.next_message(session, 1_000) == {:ok, "later-event"}
  end

  test "connection establishment timeout is distinct from receive inactivity" do
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

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
