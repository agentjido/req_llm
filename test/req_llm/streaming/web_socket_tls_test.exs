defmodule ReqLLM.Streaming.WebSocketTLSTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Streaming.WebSocketSession

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/socket" do
      send(
        Application.fetch_env!(:req_llm, :web_socket_tls_test_pid),
        {:web_socket_tls_request, Map.new(conn.req_headers)}
      )

      WebSockAdapter.upgrade(conn, ReqLLM.Streaming.WebSocketTLSTest.Socket, nil, [])
    end
  end

  defmodule Socket do
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({_message, _opts}, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  setup do
    Application.put_env(:req_llm, :web_socket_tls_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:req_llm, :web_socket_tls_test_pid)
    end)

    {server_tls_options, cacerts} = tls_options()

    {:ok, server} =
      Bandit.start_link(
        plug: Router,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        thousand_island_options: [transport_options: server_tls_options]
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, url: "wss://localhost:#{port}/socket", cacerts: cacerts}
  end

  test "rejects an untrusted WebSocket certificate", %{url: url} do
    {:ok, session} =
      WebSocketSession.start_link(url,
        headers: [{"authorization", "Bearer test-token"}],
        connect_timeout: 1_000
      )

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             WebSocketSession.await_connected(session, 1_000)

    refute_received {:web_socket_tls_request, _headers}
    assert :ok = WebSocketSession.close(session)
  end

  test "rejects an untrusted certificate for an HTTPS URL", %{url: url} do
    https_url = String.replace_prefix(url, "wss://", "https://")

    {:ok, session} =
      WebSocketSession.start_link(https_url,
        headers: [{"authorization", "Bearer test-token"}],
        connect_timeout: 1_000
      )

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             WebSocketSession.await_connected(session, 1_000)

    refute_received {:web_socket_tls_request, _headers}
    assert :ok = WebSocketSession.close(session)
  end

  test "rejects a trusted certificate for the wrong host", %{url: url, cacerts: cacerts} do
    wrong_host_url = String.replace(url, "localhost", "127.0.0.1")

    {:ok, session} =
      WebSocketSession.start_link(wrong_host_url,
        headers: [{"authorization", "Bearer test-token"}],
        connect_timeout: 1_000,
        req_http_options: [connect_options: [transport_opts: [cacerts: cacerts]]]
      )

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             WebSocketSession.await_connected(session, 1_000)

    refute_received {:web_socket_tls_request, _headers}
    assert :ok = WebSocketSession.close(session)
  end

  test "accepts a WebSocket certificate from req_http_options", %{
    url: url,
    cacerts: cacerts
  } do
    {:ok, session} =
      WebSocketSession.start_link(url,
        headers: [{"authorization", "Bearer test-token"}],
        connect_timeout: 1_000,
        req_http_options: [connect_options: [transport_opts: [cacerts: cacerts]]]
      )

    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:web_socket_tls_request, %{"authorization" => "Bearer test-token"}}
    assert :ok = WebSocketSession.close(session)
  end

  test "accepts a WebSocket certificate from a custom CA file", %{
    url: url,
    cacerts: cacerts
  } do
    cacertfile = write_cacertfile(cacerts)

    {:ok, session} =
      WebSocketSession.start_link(url,
        connect_timeout: 1_000,
        req_http_options: [connect_options: [transport_opts: [cacertfile: cacertfile]]]
      )

    assert :ok = WebSocketSession.await_connected(session, 1_000)
    assert_receive {:web_socket_tls_request, _headers}
    assert :ok = WebSocketSession.close(session)
  end

  defp write_cacertfile(cacerts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "req_llm-websocket-ca-#{System.unique_integer([:positive])}.pem"
      )

    pem_entries = Enum.map(cacerts, &{:Certificate, &1, :not_encrypted})
    File.write!(path, :public_key.pem_encode(pem_entries))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp tls_options do
    chain = %{
      root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
      intermediates: [],
      peer: [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
      ]
    }

    data = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})
    {Keyword.take(data[:server_config], [:cert, :key]), data[:client_config][:cacerts]}
  end
end
