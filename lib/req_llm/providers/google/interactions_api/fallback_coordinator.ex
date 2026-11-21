defmodule ReqLLM.Providers.Google.InteractionsAPI.FallbackCoordinator do
  @moduledoc false

  use GenServer

  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  defstruct [
    :caller,
    :start_fallback,
    :starter,
    fallback: :pending,
    primary_404: :unknown,
    stream_done?: false,
    meta_done?: false,
    waiters: []
  ]

  @type fallback_result :: {:ok, StreamResponse.t()} | {:error, term()}

  @spec start_link(pid(), (-> fallback_result())) :: GenServer.on_start()
  def start_link(caller, start_fallback)
      when is_pid(caller) and is_function(start_fallback, 0) do
    GenServer.start_link(__MODULE__, {caller, start_fallback})
  end

  @spec start_fallback(pid()) :: fallback_result()
  def start_fallback(coordinator) when is_pid(coordinator) do
    safe_call(coordinator, :start_fallback, {:error, :cancelled})
  end

  @spec primary_404(pid()) :: :unknown | {:known, boolean()} | :stopped
  def primary_404(coordinator) when is_pid(coordinator) do
    safe_call(coordinator, :primary_404, :stopped)
  end

  @spec set_primary_404(pid(), boolean()) :: :ok
  def set_primary_404(coordinator, not_found?)
      when is_pid(coordinator) and is_boolean(not_found?) do
    safe_call(coordinator, {:set_primary_404, not_found?}, :ok)
  end

  @spec finish_consumer(pid(), :stream | :meta) :: {:cleanup, term()} | :keep
  def finish_consumer(coordinator, consumer)
      when is_pid(coordinator) and consumer in [:stream, :meta] do
    safe_call(coordinator, {:finish_consumer, consumer}, :keep)
  end

  @spec cancel(pid()) :: {:ok, StreamResponse.t()} | :none
  def cancel(coordinator) when is_pid(coordinator) do
    safe_call(coordinator, :cancel, :none)
  end

  @spec cleanup_fallback(term()) :: :ok
  def cleanup_fallback({:started, {:ok, %StreamResponse{} = fallback}}) do
    do_cleanup_fallback(fallback)
  end

  def cleanup_fallback({:ok, %StreamResponse{} = fallback}) do
    do_cleanup_fallback(fallback)
  end

  def cleanup_fallback(%StreamResponse{} = fallback) do
    do_cleanup_fallback(fallback)
  end

  def cleanup_fallback(_other), do: :ok

  @spec safe_cancel_stream(StreamResponse.t() | term()) :: :ok
  def safe_cancel_stream(%StreamResponse{cancel: cancel}) when is_function(cancel, 0) do
    cancel.()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_cancel_stream(_other), do: :ok

  @spec safe_stop_metadata_handle(pid() | term()) :: :ok
  def safe_stop_metadata_handle(handle) when is_pid(handle) do
    MetadataHandle.stop(handle)
  catch
    :exit, _ -> :ok
  end

  def safe_stop_metadata_handle(_other), do: :ok

  @impl GenServer
  def init({caller, start_fallback}) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{caller: caller, start_fallback: start_fallback}}
  end

  @impl GenServer
  def handle_call(:start_fallback, _from, %__MODULE__{fallback: {:started, result}} = state) do
    {:reply, result, state}
  end

  def handle_call(:start_fallback, from, %__MODULE__{fallback: :starting} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:start_fallback, from, %__MODULE__{fallback: :pending} = state) do
    starter = spawn_starter(self(), state.start_fallback)

    {:noreply, %{state | fallback: :starting, starter: starter, waiters: [from | state.waiters]}}
  end

  def handle_call(
        {:fallback_started, token, result},
        _from,
        %__MODULE__{starter: {_pid, ref, token}} = state
      ) do
    Process.demonitor(ref, [:flush])
    reply_waiters(state.waiters, result)
    {:reply, :ok, %{state | fallback: {:started, result}, starter: nil, waiters: []}}
  end

  def handle_call({:fallback_started, _token, _result}, _from, %__MODULE__{} = state) do
    {:reply, :ignore, state}
  end

  def handle_call(:primary_404, _from, %__MODULE__{} = state) do
    {:reply, state.primary_404, state}
  end

  def handle_call({:set_primary_404, not_found?}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | primary_404: {:known, not_found?}}}
  end

  def handle_call({:finish_consumer, consumer}, _from, %__MODULE__{} = state) do
    next = mark_consumer_done(state, consumer)

    done? =
      (next.meta_done? and next.primary_404 == {:known, false} and next.fallback == :pending) or
        (next.meta_done? and next.stream_done?)

    if done? do
      reply_waiters(next.waiters, {:error, :cancelled})
      {:stop, :normal, {:cleanup, next.fallback}, %{next | waiters: []}}
    else
      {:reply, :keep, next}
    end
  end

  def handle_call(:cancel, _from, %__MODULE__{} = state) do
    reply_waiters(state.waiters, {:error, :cancelled})

    reply =
      case state.fallback do
        {:started, {:ok, %StreamResponse{} = fallback}} -> {:ok, fallback}
        _ -> :none
      end

    {:stop, :normal, reply, %{state | waiters: []}}
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %__MODULE__{starter: {pid, ref, _token}} = state
      ) do
    error_reason = if(reason == :normal, do: :cancelled, else: reason)
    result = {:error, error_reason}
    reply_waiters(state.waiters, result)
    {:noreply, %{state | fallback: {:started, result}, starter: nil, waiters: []}}
  end

  def handle_info({:EXIT, caller_pid, :normal}, %__MODULE__{caller: caller_pid} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, caller_pid, reason}, %__MODULE__{caller: caller_pid} = state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, %__MODULE__{} = state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(:normal, %__MODULE__{} = state) do
    reply_waiters(state.waiters, {:error, :cancelled})
    :ok
  end

  def terminate(_reason, %__MODULE__{} = state) do
    reply_waiters(state.waiters, {:error, :cancelled})
    cleanup_fallback(state.fallback)
    :ok
  end

  defp spawn_starter(coordinator, start_fallback) do
    token = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        coord_ref = Process.monitor(coordinator)
        result = run_start_fallback(start_fallback)

        if report_fallback_result(coordinator, token, result) do
          hold_parent_until_coordinator_exits(coord_ref, coordinator, result)
        else
          Process.demonitor(coord_ref, [:flush])
          cleanup_fallback(result)
        end
      end)

    {pid, ref, token}
  end

  defp hold_parent_until_coordinator_exits(
         coord_ref,
         coordinator,
         {:ok, %StreamResponse{}} = result
       ) do
    receive do
      {:DOWN, ^coord_ref, :process, ^coordinator, :normal} ->
        :ok

      {:DOWN, ^coord_ref, :process, ^coordinator, _reason} ->
        cleanup_fallback(result)
    end
  end

  defp hold_parent_until_coordinator_exits(coord_ref, _coordinator, _result) do
    Process.demonitor(coord_ref, [:flush])
    :ok
  end

  defp run_start_fallback(start_fallback) do
    start_fallback.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
    :throw, value -> {:error, {:throw, value}}
  end

  defp report_fallback_result(coordinator, token, result) do
    GenServer.call(coordinator, {:fallback_started, token, result}, :infinity) == :ok
  catch
    :exit, _ -> false
  end

  defp safe_call(coordinator, message, default) do
    GenServer.call(coordinator, message, :infinity)
  catch
    :exit, _ -> default
  end

  defp reply_waiters(waiters, reply) do
    waiters
    |> Enum.reverse()
    |> Enum.each(&GenServer.reply(&1, reply))
  end

  defp mark_consumer_done(%__MODULE__{} = state, :stream), do: %{state | stream_done?: true}
  defp mark_consumer_done(%__MODULE__{} = state, :meta), do: %{state | meta_done?: true}

  defp do_cleanup_fallback(%StreamResponse{} = fallback) do
    safe_cancel_stream(fallback)
    safe_stop_metadata_handle(fallback.metadata_handle)
    :ok
  end
end
