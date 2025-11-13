defmodule ReqLLM.StreamResponse.MetadataHandle do
  @moduledoc """
  Asynchronous metadata cache that allows multiple awaiters to share the same result.

  The handle starts a background process that runs the supplied fetch fun exactly once.
  Callers can await the metadata multiple times without causing repeated fetches or
  task mailbox exhaustion.
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

  @impl true
  def init(fetch_fun) do
    state = %{fetch_fun: fetch_fun, metadata: :pending, waiters: []}
    {:ok, state, {:continue, :collect_metadata}}
  end

  @impl true
  def handle_continue(:collect_metadata, %{fetch_fun: fetch_fun} = state) do
    metadata =
      try do
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

    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, metadata}))
    {:noreply, %{state | metadata: {:ready, metadata}, waiters: [], fetch_fun: nil}}
  end

  @impl true
  def handle_call(:await, _from, %{metadata: {:ready, metadata}} = state) do
    {:reply, {:ok, metadata}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end
end
