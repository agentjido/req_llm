defmodule ReqLLM.Schema.EvictionStrategy.LRU do
  @moduledoc """
  Removes the least recently used JSON Schema validator.
  """

  @behaviour ReqLLM.Schema.EvictionStrategy

  @impl true
  def select_victim(entries) do
    Enum.min_by(entries, & &1.last_access)
  end
end
