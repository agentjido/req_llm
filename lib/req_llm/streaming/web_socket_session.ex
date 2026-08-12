defmodule ReqLLM.Streaming.WebSocketSession do
  @moduledoc false

  use GenServer

  alias ReqLLM.Streaming.WebSocketSession.Client

  @type status :: :connecting | :open | :closed | {:error, term()}

  defstruct [
    :client_pid,
    :client_ref,
    connect_timeout: 10_000,
    status: :connecting,
    queue: :queue.new(),
    initial_messages: [],
    waiting_callers: [],
    waiting_connect_callers: [],
    http_fallback?: false
  ]

  @type t :: pid()

  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(url, opts \\ []) when is_binary(url) do
    GenServer.start_link(__MODULE__, {url, opts})
  end

  @spec await_connected(t(), timeout()) :: :ok | {:error, term()}
  def await_connected(server, timeout \\ 10_000)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    GenServer.call(server, {:await_connected, timeout}, :infinity)
  end

  @spec next_message(t(), timeout()) :: {:ok, binary()} | :halt | {:error, term()}
  def next_message(server, timeout \\ 30_000)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    GenServer.call(server, {:next_message, timeout}, :infinity)
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

  @spec mark_http_fallback(t()) :: :ok
  def mark_http_fallback(server) do
    GenServer.call(server, :mark_http_fallback)
  end

  @spec http_fallback?(t()) :: boolean()
  def http_fallback?(server) do
    GenServer.call(server, :http_fallback?)
  end

  @impl GenServer
  def init({url, opts}) do
    initial_messages = Keyword.get(opts, :initial_messages, [])
    connect_timeout = Keyword.get(opts, :connect_timeout, 10_000)

    case Client.start(url, self(),
           headers: Keyword.get(opts, :headers, []),
           socket_connect_timeout: connect_timeout,
           socket_recv_timeout: connect_timeout
         ) do
      {:ok, client_pid} ->
        client_ref = Process.monitor(client_pid)

        state = %__MODULE__{
          client_pid: client_pid,
          client_ref: client_ref,
          connect_timeout: connect_timeout,
          initial_messages: initial_messages
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:await_connected, _timeout}, _from, %{status: :open} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:await_connected, _timeout}, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:await_connected, _timeout}, _from, %{status: {:error, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:await_connected, timeout}, from, state) do
    waiter = new_waiter(from, :connect, timeout)
    {:noreply, %{state | waiting_connect_callers: state.waiting_connect_callers ++ [waiter]}}
  end

  def handle_call({:next_message, timeout}, from, state) do
    case dequeue_message(state) do
      {:ok, message, new_state} ->
        {:reply, {:ok, message}, new_state}

      {:empty, %{status: :closed} = new_state} ->
        {:reply, :halt, new_state}

      {:empty, %{status: {:error, reason}} = new_state} ->
        {:reply, {:error, reason}, new_state}

      {:empty, new_state} ->
        waiter = new_waiter(from, :receive, timeout)
        {:noreply, %{new_state | waiting_callers: new_state.waiting_callers ++ [waiter]}}
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

  def handle_call(:mark_http_fallback, _from, state) do
    {:reply, :ok, %{state | http_fallback?: true}}
  end

  def handle_call(:http_fallback?, _from, state) do
    {:reply, state.http_fallback?, state}
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
    status = normalize_disconnect_reason(reason, state)

    state =
      state
      |> Map.put(:status, status)
      |> reply_to_connect_callers(connection_reply(status))
      |> reply_to_waiting_callers()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _down_reason},
        %{client_ref: ref, status: {:error, _status_reason}} = state
      ) do
    {:noreply, %{state | client_pid: nil, client_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{client_ref: ref} = state) do
    status = normalize_disconnect_reason(reason, state)

    state =
      state
      |> Map.put(:status, status)
      |> Map.put(:client_pid, nil)
      |> Map.put(:client_ref, nil)
      |> reply_to_connect_callers(connection_reply(status))
      |> reply_to_waiting_callers()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, remove_waiter(state, ref)}
  end

  def handle_info({:waiter_timeout, :connect, monitor, timeout}, state) do
    {:noreply, expire_waiter(state, :waiting_connect_callers, monitor, :connect, timeout)}
  end

  def handle_info({:waiter_timeout, :receive, monitor, timeout}, state) do
    {:noreply, expire_waiter(state, :waiting_callers, monitor, :receive, timeout)}
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

  defp enqueue_or_reply(message, %{waiting_callers: [waiter | rest]} = state) do
    cancel_waiter(waiter)
    state = %{state | waiting_callers: rest}

    if Process.alive?(elem(waiter.from, 0)) do
      GenServer.reply(waiter.from, {:ok, message})
      state
    else
      enqueue_or_reply(message, state)
    end
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
    Enum.each(state.waiting_connect_callers, &reply_waiter(&1, reply))
    %{state | waiting_connect_callers: []}
  end

  defp reply_to_waiting_callers(%{status: :open} = state), do: state

  defp reply_to_waiting_callers(%{status: status} = state) do
    reply =
      case status do
        :closed -> :halt
        {:error, reason} -> {:error, reason}
      end

    Enum.each(state.waiting_callers, &reply_waiter(&1, reply))
    %{state | waiting_callers: []}
  end

  defp connection_reply(:closed), do: {:error, :closed}
  defp connection_reply({:error, reason}), do: {:error, reason}

  defp new_waiter(from, kind, timeout) do
    monitor = Process.monitor(elem(from, 0))

    %{
      from: from,
      timer: waiter_timer(kind, timeout, monitor),
      monitor: monitor
    }
  end

  defp waiter_timer(_kind, :infinity, _monitor), do: nil

  defp waiter_timer(kind, timeout, monitor),
    do: Process.send_after(self(), {:waiter_timeout, kind, monitor, timeout}, timeout)

  defp cancel_waiter(waiter) do
    if waiter.timer, do: Process.cancel_timer(waiter.timer, async: true, info: false)
    Process.demonitor(waiter.monitor, [:flush])
  end

  defp reply_waiter(waiter, reply) do
    cancel_waiter(waiter)
    GenServer.reply(waiter.from, reply)
  end

  defp expire_waiter(state, field, monitor, kind, timeout) do
    {expired, remaining} = Enum.split_with(Map.fetch!(state, field), &(&1.monitor == monitor))

    Enum.each(expired, fn waiter ->
      error = ReqLLM.Error.API.Timeout.exception(kind: kind, timeout: timeout)
      reply_waiter(waiter, {:error, error})
    end)

    Map.put(state, field, remaining)
  end

  defp remove_waiter(state, monitor) do
    Enum.reduce([:waiting_connect_callers, :waiting_callers], state, fn field, state ->
      {removed, remaining} =
        Enum.split_with(Map.fetch!(state, field), &(&1.monitor == monitor))

      Enum.each(removed, &cancel_waiter/1)
      Map.put(state, field, remaining)
    end)
  end

  defp normalize_disconnect_reason(
         %{original: :timeout},
         %{status: :connecting, connect_timeout: timeout}
       ) do
    {:error, ReqLLM.Error.API.Timeout.exception(kind: :connect, timeout: timeout)}
  end

  defp normalize_disconnect_reason(reason, _state), do: normalize_disconnect_reason(reason)

  defp normalize_disconnect_reason(:normal), do: :closed
  defp normalize_disconnect_reason({:local, :normal}), do: :closed
  defp normalize_disconnect_reason({:remote, :normal}), do: :closed
  defp normalize_disconnect_reason({:remote, :closed}), do: :closed

  defp normalize_disconnect_reason({side, 1000, _detail}) when side in [:local, :remote],
    do: :closed

  defp normalize_disconnect_reason(:shutdown), do: :closed
  defp normalize_disconnect_reason({:shutdown, _reason}), do: :closed
  defp normalize_disconnect_reason(reason), do: {:error, reason}
end
