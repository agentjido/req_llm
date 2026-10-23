defmodule ReqLLM.Streaming.WebSocketSession.Client do
  @moduledoc false

  use WebSockex

  @spec start(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(url, owner, opts \\ []) do
    state = %{owner: owner}

    ws_opts =
      [
        async: true,
        handle_initial_conn_failure: true,
        extra_headers: Keyword.get(opts, :headers, [])
      ]
      |> Keyword.merge(
        Keyword.take(opts, [
          :name,
          :debug,
          :async,
          :handle_initial_conn_failure,
          :socket_connect_timeout,
          :socket_recv_timeout
        ])
      )
      |> maybe_put_tls_options(url, opts)

    WebSockex.start(url, __MODULE__, state, ws_opts)
  end

  defp maybe_put_tls_options(ws_opts, url, opts) do
    if url |> URI.parse() |> Map.get(:scheme) |> secure_scheme?() do
      ws_opts
      |> Keyword.put(:insecure, false)
      |> Keyword.put(:ssl_options, ssl_options(opts))
    else
      ws_opts
    end
  end

  defp secure_scheme?(scheme) when is_binary(scheme),
    do: String.downcase(scheme) in ["wss", "https"]

  defp secure_scheme?(_scheme), do: false

  defp ssl_options(opts) do
    defaults = [
      verify: :verify_peer,
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    defaults
    |> Keyword.merge(trust_store_options(opts))
    |> Keyword.merge(user_ssl_options(opts))
  end

  defp trust_store_options(opts) do
    user_ssl_options = user_ssl_options(opts)

    cond do
      Keyword.has_key?(user_ssl_options, :cacerts) ->
        []

      Keyword.has_key?(user_ssl_options, :cacertfile) ->
        []

      Keyword.has_key?(opts, :cacerts) ->
        [cacerts: Keyword.fetch!(opts, :cacerts)]

      true ->
        default_trust_store_options()
    end
  end

  defp default_trust_store_options do
    [cacerts: :public_key.cacerts_get()]
  rescue
    _error -> []
  end

  defp user_ssl_options(opts), do: Keyword.get(opts, :ssl_options, [])

  @spec send_frame(pid(), WebSockex.frame()) :: :ok
  def send_frame(client, frame) do
    WebSockex.cast(client, {:send_frame, frame})
  end

  @spec close(pid()) :: :ok
  def close(client) do
    WebSockex.cast(client, :close)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:web_socket_session, self(), :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame(frame, state) do
    send(state.owner, {:web_socket_session, self(), {:frame, frame}})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(connection_status_map, state) do
    send(
      state.owner,
      {:web_socket_session, self(), {:disconnected, connection_status_map.reason}}
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_frame, frame}, state) do
    {:reply, frame, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end
end
