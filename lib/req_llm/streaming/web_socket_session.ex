defmodule ReqLLM.Streaming.WebSocketSession do
  @moduledoc false

  use GenServer

  alias ReqLLM.Streaming.WebSocketSession.Client

  @type status :: :connecting | :open | :closed | {:error, term()}

  defstruct [
    :client_pid,
    :client_ref,
    status: :connecting,
    queue: :queue.new(),
    initial_messages: [],
    waiting_callers: [],
    waiting_connect_callers: []
  ]

  @type t :: pid()

  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(url, opts \\ []) when is_binary(url) do
    GenServer.start_link(__MODULE__, {url, opts})
  end

  @spec await_connected(t(), non_neg_integer()) :: :ok | {:error, term()}
  def await_connected(server, timeout \\ 10_000) do
    GenServer.call(server, :await_connected, timeout + 1000)
  end

  @spec next_message(t(), non_neg_integer()) :: {:ok, binary()} | :halt | {:error, term()}
  def next_message(server, timeout \\ 30_000) do
    GenServer.call(server, {:next_message, timeout}, timeout + 1000)
  end

  @spec send_json(t(), map()) :: :ok | {:error, term()}
  def send_json(server, payload) when is_map(payload) do
    GenServer.call(server, {:send_text, Jason.encode!(payload)})
  end

  @spec send_text(t(), binary()) :: :ok | {:error, term()}
  def send_text(server, text) when is_binary(text) do
    GenServer.call(server, {:send_text, text})
  end

  @spec close(t()) :: :ok
  def close(server) do
    GenServer.call(server, :close)
  end

  @impl GenServer
  def init({url, opts}) do
    initial_messages = Keyword.get(opts, :initial_messages, [])

    case Client.start(url, self(), headers: Keyword.get(opts, :headers, [])) do
      {:ok, client_pid} ->
        client_ref = Process.monitor(client_pid)

        state = %__MODULE__{
          client_pid: client_pid,
          client_ref: client_ref,
          initial_messages: initial_messages
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:await_connected, _from, %{status: :open} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_connected, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:await_connected, _from, %{status: {:error, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:await_connected, from, state) do
    {:noreply, %{state | waiting_connect_callers: state.waiting_connect_callers ++ [from]}}
  end

  def handle_call({:next_message, _timeout}, from, state) do
    case dequeue_message(state) do
      {:ok, message, new_state} ->
        {:reply, {:ok, message}, new_state}

      {:empty, %{status: :closed} = new_state} ->
        {:reply, :halt, new_state}

      {:empty, %{status: {:error, reason}} = new_state} ->
        {:reply, {:error, reason}, new_state}

      {:empty, new_state} ->
        {:noreply, %{new_state | waiting_callers: new_state.waiting_callers ++ [from]}}
    end
  end

  def handle_call({:send_text, _text}, _from, %{status: :connecting} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_text, _text}, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send_text, _text}, _from, %{status: {:error, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:send_text, text}, _from, %{client_pid: client_pid} = state) do
    :ok = Client.send_frame(client_pid, {:text, text})
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    if is_pid(state.client_pid) and Process.alive?(state.client_pid) do
      :ok = Client.close(state.client_pid)
    end

    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  @impl GenServer
  def handle_info({:web_socket_session, _pid, :connected}, state) do
    Enum.each(state.initial_messages, fn message ->
      :ok = Client.send_frame(state.client_pid, {:text, message})
    end)

    state =
      state
      |> Map.put(:status, :open)
      |> Map.put(:initial_messages, [])
      |> reply_to_connect_callers(:ok)

    {:noreply, state}
  end

  def handle_info({:web_socket_session, _pid, {:frame, {:text, payload}}}, state) do
    {:noreply, enqueue_or_reply(payload, state)}
  end

  def handle_info({:web_socket_session, _pid, {:frame, {:binary, payload}}}, state) do
    {:noreply, enqueue_or_reply(payload, state)}
  end

  def handle_info({:web_socket_session, _pid, {:disconnected, reason}}, state) do
    status = normalize_disconnect_reason(reason)

    state =
      state
      |> Map.put(:status, status)
      |> reply_to_connect_callers(connection_reply(status))
      |> reply_to_waiting_callers()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{client_ref: ref} = state) do
    status = normalize_disconnect_reason(reason)

    state =
      state
      |> Map.put(:status, status)
      |> Map.put(:client_pid, nil)
      |> Map.put(:client_ref, nil)
      |> reply_to_connect_callers(connection_reply(status))
      |> reply_to_waiting_callers()

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if is_pid(state.client_pid) and Process.alive?(state.client_pid) do
      Process.exit(state.client_pid, :shutdown)
    end

    :ok
  end

  defp enqueue_or_reply(message, %{waiting_callers: [from | rest]} = state) do
    GenServer.reply(from, {:ok, message})
    %{state | waiting_callers: rest}
  end

  defp enqueue_or_reply(message, state) do
    %{state | queue: :queue.in(message, state.queue)}
  end

  defp dequeue_message(state) do
    case :queue.out(state.queue) do
      {{:value, message}, queue} -> {:ok, message, %{state | queue: queue}}
      {:empty, _queue} -> {:empty, state}
    end
  end

  defp reply_to_connect_callers(state, reply) do
    Enum.each(state.waiting_connect_callers, &GenServer.reply(&1, reply))
    %{state | waiting_connect_callers: []}
  end

  defp reply_to_waiting_callers(%{status: :open} = state), do: state

  defp reply_to_waiting_callers(%{status: status} = state) do
    reply =
      case status do
        :closed -> :halt
        {:error, reason} -> {:error, reason}
      end

    Enum.each(state.waiting_callers, &GenServer.reply(&1, reply))
    %{state | waiting_callers: []}
  end

  defp connection_reply(:closed), do: {:error, :closed}
  defp connection_reply({:error, reason}), do: {:error, reason}

  defp normalize_disconnect_reason(:normal), do: :closed
  defp normalize_disconnect_reason({:local, :normal}), do: :closed
  defp normalize_disconnect_reason({:remote, :normal}), do: :closed
  defp normalize_disconnect_reason({:remote, :closed}), do: :closed
  defp normalize_disconnect_reason(:shutdown), do: :closed
  defp normalize_disconnect_reason({:shutdown, _reason}), do: :closed
  defp normalize_disconnect_reason(reason), do: {:error, reason}
end
