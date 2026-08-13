defmodule ReqLLM.LLMDBReleaseFixture.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {:ok, %LLMDB.Model{provider: :openai}} = ReqLLM.model("openai:gpt-4o-mini")

    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
