defmodule ReqLLM.Providers.GoogleVertex.TokenCache do
  @moduledoc """
  OAuth2 token cache for Google Vertex AI.

  Caches access tokens per service account to avoid expensive token
  generation on every request.

  ## Lifecycle

  - Started by ReqLLM.Application supervision tree
  - One cache per node (not distributed)
  - Tokens cached for 55 minutes (5 minute safety margin)

  ## Usage

      # Provider calls this instead of Auth.get_access_token/1 directly
      {:ok, token} = TokenCache.get_or_refresh(service_account_json_path)

  ## Cache Key

  Service account JSON file path (string). This allows multiple service
  accounts to be used simultaneously with independent token caches.

  ## Expiry & Refresh

  Tokens are cached for 55 minutes (5 minute safety margin before 1 hour expiry).
  The GenServer serializes concurrent refresh requests to prevent duplicate token
  fetches when the cache is empty or expired.
  """

  use GenServer

  require Logger

  @table_name :vertex_oauth2_tokens
  @token_lifetime_seconds 3600
  @safety_margin_seconds 300
  @cache_ttl_seconds @token_lifetime_seconds - @safety_margin_seconds

  ## Client API

  @doc """
  Retrieves a cached token or fetches a fresh one if expired.

  This is the only function providers should call. It handles:
  - Cache hits (fast path)
  - Cache misses (slow path with fetch)
  - Expiry checking
  - Concurrent request deduplication

  ## Examples

      iex> TokenCache.get_or_refresh("/path/to/service-account.json")
      {:ok, "ya29.c.Kl6iB..."}

      iex> TokenCache.get_or_refresh("/invalid/path.json")
      {:error, :enoent}
  """
  @spec get_or_refresh(service_account_json_path :: String.t()) ::
          {:ok, access_token :: String.t()} | {:error, term()}
  def get_or_refresh(service_account_json_path) do
    GenServer.call(__MODULE__, {:get_or_refresh, service_account_json_path})
  end

  @doc """
  Invalidates cached token for a service account.

  Useful for testing or when credentials are rotated.
  """
  @spec invalidate(service_account_json_path :: String.t()) :: :ok
  def invalidate(service_account_json_path) do
    GenServer.call(__MODULE__, {:invalidate, service_account_json_path})
  end

  @doc """
  Clears all cached tokens.

  Useful for testing.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  ## Server Implementation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :private, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:get_or_refresh, service_account_json_path}, _from, state) do
    case lookup_token(state.table, service_account_json_path) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :expired ->
        refresh_and_cache(state, service_account_json_path)

      :not_found ->
        refresh_and_cache(state, service_account_json_path)
    end
  end

  @impl true
  def handle_call({:invalidate, service_account_json_path}, _from, state) do
    :ets.delete(state.table, service_account_json_path)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  ## Private Helpers

  defp lookup_token(table, key) do
    case :ets.lookup(table, key) do
      [] ->
        :not_found

      [{^key, token, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, token}
        else
          :expired
        end
    end
  end

  defp refresh_and_cache(state, service_account_json_path) do
    case ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json_path) do
      {:ok, token} ->
        expires_at = System.system_time(:second) + @cache_ttl_seconds
        :ets.insert(state.table, {service_account_json_path, token, expires_at})

        Logger.debug(
          "Cached OAuth2 token for #{service_account_json_path}, expires in #{@cache_ttl_seconds}s"
        )

        {:reply, {:ok, token}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
