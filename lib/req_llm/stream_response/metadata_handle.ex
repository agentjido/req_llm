defmodule ReqLLM.StreamResponse.MetadataHandle do
  @moduledoc """
  Asynchronous metadata cache that allows multiple awaiters to share the same result.

  The handle starts a background process that runs the supplied fetch fun exactly once.
  Callers can await the metadata multiple times without causing repeated fetches or
  task mailbox exhaustion. Call `stop/1` when the cached metadata is no longer needed.
  """

  use GenServer

  require Logger

  @type t :: pid()

  @spec start_link((-> map())) :: {:ok, t()} | {:error, term()}
  def start_link(fetch_fun) when is_function(fetch_fun, 0) do
    GenServer.start_link(__MODULE__, fetch_fun)
  end

  @spec await(t(), timeout()) :: map()
  def await(handle, timeout \\ :infinity) when is_pid(handle) do
    case GenServer.call(handle, :await, timeout) do
      {:ok, metadata} -> metadata
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Stops a metadata handle and any in-progress metadata collection.

  This operation is idempotent and returns `:ok` when the handle has already stopped.
  """
  @spec stop(t()) :: :ok
  def stop(handle) when is_pid(handle) do
    monitor_ref = Process.monitor(handle)
    GenServer.cast(handle, :stop)

    receive do
      {:DOWN, ^monitor_ref, :process, ^handle, _reason} -> :ok
    end
  end

  @impl true
  def init(fetch_fun) do
    state = %{fetch_fun: fetch_fun, metadata: :pending, waiters: [], worker: nil}
    {:ok, state, {:continue, :collect_metadata}}
  end

  @impl true
  def handle_continue(:collect_metadata, %{fetch_fun: fetch_fun} = state) do
    parent = self()

    worker =
      :erlang.spawn_opt(
        fn ->
          send(parent, {:metadata_collected, self(), collect_metadata(fetch_fun)})
        end,
        [:link, :monitor]
      )

    {:noreply, %{state | fetch_fun: nil, worker: worker}}
  end

  @impl true
  def handle_call(:await, _from, %{metadata: {:ready, metadata}} = state) do
    {:reply, {:ok, metadata}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(
        {:metadata_collected, worker_pid, metadata},
        %{worker: {worker_pid, monitor_ref}} = state
      ) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, metadata_ready(state, metadata)}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, worker_pid, reason},
        %{worker: {worker_pid, monitor_ref}} = state
      ) do
    Logger.warning("Metadata collection exited: #{inspect(reason)}")
    {:noreply, metadata_ready(state, %{})}
  end

  @impl true
  def terminate(_reason, %{worker: {worker_pid, monitor_ref}}) do
    Process.unlink(worker_pid)
    Process.demonitor(monitor_ref, [:flush])
    Process.exit(worker_pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp collect_metadata(fetch_fun) do
    fetch_fun.()
  rescue
    error ->
      Logger.warning(
        "Metadata collection failed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      %{}
  catch
    :exit, reason ->
      Logger.warning("Metadata collection exited: #{inspect(reason)}")
      %{}
  end

  defp metadata_ready(state, metadata) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, metadata}))
    %{state | metadata: {:ready, metadata}, waiters: [], worker: nil}
  end
end
