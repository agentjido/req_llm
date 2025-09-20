defmodule ReqLLM.Application do
  @moduledoc """
  Application module for ReqLLM.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ReqLLM.Provider.Registry.initialize()

    opts = [strategy: :one_for_one, name: ReqLLM.Supervisor]
    Supervisor.start_link([], opts)
  end
end
