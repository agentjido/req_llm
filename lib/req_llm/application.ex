defmodule ReqLLM.Application do
  @moduledoc """
  Application supervisor for ReqLLM.

  Starts and supervises the Finch instance used for streaming LLM APIs.
  Provides optimized connection pools per provider with sensible defaults
  that can be overridden via application configuration.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ReqLLM.Provider.Registry.initialize()

    finch_config = get_finch_config()

    children =
      [
        {Finch, finch_config},
        {Task.Supervisor, name: ReqLLM.TaskSupervisor}
      ] ++ dev_children()

    opts = [strategy: :one_for_one, name: ReqLLM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Gets the Finch configuration from application environment with unified pool defaults.

  ReqLLM normalizes all providers through a single connection pool, making it as easy
  as changing the model spec to switch providers.

  Users can override pool configurations by setting:

      config :req_llm,
        finch: [
          name: ReqLLM.Finch,
          pools: %{
            :default => [protocols: [:http2, :http1], size: 1, count: 16]
          }
        ]
  """
  @spec get_finch_config() :: keyword()
  def get_finch_config do
    user_config = Application.get_env(:req_llm, :finch, [])

    default_config = [
      name: ReqLLM.Finch,
      pools: get_default_pools()
    ]

    Keyword.merge(default_config, user_config)
  end

  @doc """
  Gets the default Finch name used by ReqLLM for streaming operations.
  """
  @spec finch_name() :: atom()
  def finch_name do
    Application.get_env(:req_llm, :finch, [])
    |> Keyword.get(:name, ReqLLM.Finch)
  end

  # Unified connection pool defaults supporting all providers
  # ReqLLM's core value is provider normalization - users should be able to
  # switch providers by just changing the model spec
  defp get_default_pools do
    %{
      # Single default pool that handles all providers efficiently
      # HTTP/2 first for modern APIs, HTTP/1 fallback for compatibility
      :default => [
        protocols: [:http2, :http1],
        # Single persistent connection per pool
        size: 1,
        # 8 pools for good concurrency
        count: 8
      ]
    }
  end

  defp dev_children do
    case System.get_env("TIDEWAVE_REPL") do
      "true" ->
        ensure_tidewave_started()
        port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
        [{Bandit, plug: Tidewave, port: port}]

      _ ->
        []
    end
  end

  defp ensure_tidewave_started do
    case Application.ensure_all_started(:tidewave) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
