defmodule ReqLLM.Bedrock.BidiStreamWaitersTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Bedrock.BidiStream

  defmodule Harness do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(_), do: {:ok, %BidiStream{}}
    def handle_call(message, from, state), do: BidiStream.handle_call(message, from, state)
    def handle_info(message, state), do: BidiStream.handle_info(message, state)
  end

  setup do
    pid = start_supervised!(Harness)
    %{pid: pid, conn: %BidiStream.Conn{pid: pid, model_id: "probe"}}
  end

  test "zero and finite waits return timeout errors and preserve late events", %{
    conn: conn,
    pid: pid
  } do
    for timeout <- [0, 5] do
      assert {:error, %ReqLLM.Error.API.Timeout{kind: :receive, timeout: ^timeout}} =
               BidiStream.next_event(conn, timeout)

      assert :sys.get_state(pid).waiting == []
      event = %{"event" => %{"textOutput" => %{"content" => "late"}}}
      send(pid, {:http2_duplex, self(), {:data, BidiStream.build_inner(event)}})
      assert {:ok, ^event} = BidiStream.next_event(conn, 0)
    end
  end

  test "infinite waits receive events without timeout arithmetic", %{conn: conn, pid: pid} do
    task = Task.async(fn -> BidiStream.next_event(conn, :infinity) end)
    wait_for_waiters(pid, 1)
    event = %{"event" => %{"textOutput" => %{"content" => "ready"}}}
    send(pid, {:http2_duplex, self(), {:data, BidiStream.build_inner(event)}})
    assert Task.await(task) == {:ok, event}
    assert :sys.get_state(pid).waiting == []
  end

  test "caller death removes the waiter and does not consume later events", %{
    conn: conn,
    pid: pid
  } do
    caller = spawn(fn -> BidiStream.next_event(conn, :infinity) end)
    wait_for_waiters(pid, 1)
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    wait_for_waiters(pid, 0)
    event = %{"event" => %{"content" => "retained"}}
    send(pid, {:http2_duplex, self(), {:data, BidiStream.build_inner(event)}})
    assert {:ok, ^event} = BidiStream.next_event(conn, 0)
  end

  test "completion and errors release all waiting callers", %{conn: conn, pid: pid} do
    tasks = for _ <- 1..3, do: Task.async(fn -> BidiStream.next_event(conn, :infinity) end)
    wait_for_waiters(pid, 3)
    send(pid, {:http2_duplex, self(), {:done, 200, []}})
    assert Enum.map(tasks, &Task.await/1) == [:halt, :halt, :halt]
    assert :sys.get_state(pid).waiting == []
    assert BidiStream.next_event(conn, 0) == :halt
  end

  test "transport errors release pending callers", %{conn: conn, pid: pid} do
    task = Task.async(fn -> BidiStream.next_event(conn, :infinity) end)
    wait_for_waiters(pid, 1)
    send(pid, {:http2_duplex, self(), {:error, :transport_failed}})
    assert Task.await(task) == {:error, :transport_failed}
  end

  defp wait_for_waiters(pid, count, attempts \\ 100)
  defp wait_for_waiters(pid, count, 0), do: assert(length(:sys.get_state(pid).waiting) == count)

  defp wait_for_waiters(pid, count, attempts) do
    if length(:sys.get_state(pid).waiting) != count do
      Process.sleep(1)
      wait_for_waiters(pid, count, attempts - 1)
    end
  end
end
