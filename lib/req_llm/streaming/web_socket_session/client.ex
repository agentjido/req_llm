defmodule ReqLLM.Streaming.WebSocketSession.Client do
  @moduledoc false

  use WebSockex

  @spec start(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(url, owner, opts \\ []) do
    state = %{owner: owner}

    ws_opts =
      [
        async: true,
        handle_initial_conn_failure: true,
        extra_headers: Keyword.get(opts, :headers, [])
      ]
      |> Keyword.merge(Keyword.take(opts, [:name, :debug, :async, :handle_initial_conn_failure]))

    WebSockex.start(url, __MODULE__, state, ws_opts)
  end

  @spec send_frame(pid(), WebSockex.frame()) :: :ok
  def send_frame(client, frame) do
    WebSockex.cast(client, {:send_frame, frame})
  end

  @spec close(pid()) :: :ok
  def close(client) do
    WebSockex.cast(client, :close)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:web_socket_session, self(), :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame(frame, state) do
    send(state.owner, {:web_socket_session, self(), {:frame, frame}})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(connection_status_map, state) do
    send(
      state.owner,
      {:web_socket_session, self(), {:disconnected, connection_status_map.reason}}
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_frame, frame}, state) do
    {:reply, frame, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end
end
