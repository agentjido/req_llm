defmodule ReqLLM.OpenTelemetry.Storage do
  @moduledoc false

  use GenServer

  @tables [:req_llm_open_telemetry_spans, :req_llm_open_telemetry_instruments]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_tables do
    if Enum.all?(@tables, &(:ets.whereis(&1) != :undefined)),
      do: :ok,
      else: GenServer.call(__MODULE__, :ensure_tables)
  end

  @impl true
  def init(_opts) do
    create_tables()
    {:ok, nil}
  end

  @impl true
  def handle_call(:ensure_tables, _from, state) do
    create_tables()
    {:reply, :ok, state}
  end

  defp create_tables do
    Enum.each(@tables, fn table ->
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])
      end
    end)
  end
end
