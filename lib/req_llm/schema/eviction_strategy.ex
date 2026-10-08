defmodule ReqLLM.Schema.EvictionStrategy do
  @moduledoc """
  Selects an entry to remove from the JSON Schema validator cache.

  ReqLLM owns the cache, enforces its memory limit, and performs eviction. A
  strategy receives cache metadata and selects one entry. It does not receive
  the compiled validator or the ETS table.
  """

  @type entry :: %{
          required(:schema) => map(),
          required(:inserted_at) => integer(),
          required(:last_access) => integer()
        }

  @callback select_victim(nonempty_list(entry())) :: entry()
end
