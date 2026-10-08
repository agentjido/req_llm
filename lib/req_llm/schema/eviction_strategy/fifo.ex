defmodule ReqLLM.Schema.EvictionStrategy.FIFO do
  @moduledoc """
  Removes the JSON Schema validator that entered the cache first.
  """

  @behaviour ReqLLM.Schema.EvictionStrategy

  @impl true
  def select_victim(entries) do
    Enum.min_by(entries, & &1.inserted_at)
  end
end
