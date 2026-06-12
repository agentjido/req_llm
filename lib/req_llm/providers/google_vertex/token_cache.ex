defmodule ReqLLM.Providers.GoogleVertex.TokenCache do
  @moduledoc """
  OAuth2 token cache for Google Vertex AI.

  Caches access tokens per Google auth source to avoid expensive token
  generation on every request.

  ## Lifecycle

  - Started by ReqLLM.Application supervision tree
  - One cache per node (not distributed)
  - Tokens cached until the auth source's reported expiry

  ## Usage

      # Provider calls this instead of Auth.get_access_token/1 directly
      {:ok, token} = TokenCache.get_or_refresh(:adc)

  ## Cache Key

  For ADC: `{:adc, scope}` is used as the cache key, where scope identifies
  the credential location (env var path, inline JSON, well-known file, or
  metadata server) so swapping credentials at runtime does not serve stale
  tokens.
  For service account file paths: the path string is used as the cache key.
  For service account JSON strings or maps: the `client_email` field is used
  as the cache key.

  This allows ADC and multiple service accounts to be used simultaneously with
  independent token caches.

  ## Expiry & Refresh

  Tokens are cached until the token expiry reported by the auth source.
  The GenServer serializes concurrent refresh requests to prevent duplicate token
  fetches when the cache is empty or expired.
  """

  use GenServer

  alias ReqLLM.Provider.Utils

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

  Accepts auth sources in multiple formats:
  - `:adc` - uses Application Default Credentials
  - `{:service_account, credentials}` - uses explicit service account credentials
  - Legacy service account credentials directly

  ## Examples

      iex> TokenCache.get_or_refresh(:adc)
      {:ok, "ya29.c.Kl6iB..."}

      iex> TokenCache.get_or_refresh({:service_account, "/path/to/service-account.json"})
      {:ok, "ya29.c.Kl6iB..."}

      iex> TokenCache.get_or_refresh("/invalid/path.json")
      {:error, :enoent}
  """
  @spec get_or_refresh(
          source :: :adc | {:service_account, String.t() | map()} | String.t() | map()
        ) ::
          {:ok, access_token :: String.t()} | {:error, term()}
  def get_or_refresh(source, opts \\ []) do
    # Resolve the cache key in the caller: it reads env vars and stats files,
    # which must not run inside the GenServer that serializes all requests.
    case resolve_cache_key(source, opts) do
      {:error, reason} ->
        {:error, reason}

      {cache_key, auth_source} ->
        GenServer.call(__MODULE__, {:get_or_refresh, cache_key, auth_source, opts})
    end
  end

  @doc """
  Invalidates cached token for an auth source.

  Useful for testing or when credentials are rotated.

  The cache key should match what was used for caching.
  """
  @spec invalidate(cache_key :: term()) :: :ok
  def invalidate(cache_key) do
    GenServer.call(__MODULE__, {:invalidate, cache_key})
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
  def handle_call({:get_or_refresh, cache_key, auth_source, opts}, _from, state) do
    case lookup_token(state.table, cache_key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      _miss ->
        refresh_and_cache(state, cache_key, auth_source, opts)
    end
  end

  @impl true
  def handle_call({:invalidate, cache_key}, _from, state) do
    :ets.delete(state.table, cache_key)
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

  defp refresh_and_cache(state, cache_key, auth_source, opts) do
    token_fetcher =
      Keyword.get(
        opts,
        :token_fetcher,
        &ReqLLM.Providers.GoogleVertex.Auth.fetch_access_token/2
      )

    case token_fetcher.(auth_source, opts) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        :ets.insert(state.table, {cache_key, token, expires_at})

        Logger.debug("Cached OAuth2 token for #{inspect(cache_key)}")

        {:reply, {:ok, token}, state}

      {:ok, token} when is_binary(token) ->
        expires_at = System.system_time(:second) + @cache_ttl_seconds
        :ets.insert(state.table, {cache_key, token, expires_at})

        Logger.debug("Cached OAuth2 token for #{inspect(cache_key)}")

        {:reply, {:ok, token}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp resolve_cache_key(:adc, opts) do
    {{:adc, ReqLLM.Providers.GoogleVertex.Auth.adc_cache_scope(opts)}, :adc}
  end

  defp resolve_cache_key({:service_account, service_account}, _opts) do
    with {:ok, cache_key} <- service_account_cache_key(service_account) do
      {{:service_account, cache_key}, {:service_account, service_account}}
    end
  end

  defp resolve_cache_key(service_account, opts) when is_map(service_account) do
    resolve_cache_key({:service_account, service_account}, opts)
  end

  defp resolve_cache_key(path_or_json, opts) when is_binary(path_or_json) do
    resolve_cache_key({:service_account, path_or_json}, opts)
  end

  defp service_account_cache_key(service_account) when is_map(service_account) do
    normalized = Utils.stringify_keys(service_account)

    case normalized["client_email"] do
      email when is_binary(email) and email != "" -> {:ok, email}
      _ -> {:error, "Invalid service account credentials: missing client_email"}
    end
  end

  defp service_account_cache_key(path_or_json) when is_binary(path_or_json) do
    if File.exists?(path_or_json) do
      {:ok, path_or_json}
    else
      case Jason.decode(path_or_json) do
        {:ok, parsed} ->
          service_account_cache_key(parsed)

        {:error, _reason} ->
          {:error,
           "Invalid service account credentials: " <>
             "not a valid file path or JSON string"}
      end
    end
  end
end
