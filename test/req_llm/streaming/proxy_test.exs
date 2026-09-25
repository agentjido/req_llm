defmodule ReqLLM.Streaming.ProxyTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Streaming.FinchClient
  alias ReqLLM.StreamResponse

  test "reuses the same pool for concurrent requests with the same connection settings" do
    finch_name = ReqLLM.Finch
    original_config = Application.fetch_env(:req_llm, :finch)
    Application.put_env(:req_llm, :finch, pools: %{default: [size: 1, count: 1]})

    on_exit(fn ->
      case original_config do
        {:ok, config} -> Application.put_env(:req_llm, :finch, config)
        :error -> Application.delete_env(:req_llm, :finch)
      end
    end)

    port = start_proxy(:reuse)
    http_options = [connect_options: [proxy: {:http, "127.0.0.1", port, []}]]
    opts = [req_http_options: http_options]
    model = ReqLLM.model!(%{provider: :openai, id: "proxy-test-model"})
    {:ok, context} = ReqLLM.Context.normalize("Hello")

    assert {:ok, request, _, _} =
             FinchClient.build_stream_request(
               ReqLLM.Providers.OpenAI,
               model,
               context,
               [base_url: "http://provider.invalid/v1", api_key: "test-key"] ++ opts,
               finch_name
             )

    pool = Finch.Pool.new("http://provider.invalid", tag: request.pool_tag)
    assert collect_stream("http://provider.invalid", opts) == "hello"
    assert {:ok, pid} = Finch.find_pool(finch_name, pool)
    assert {:ok, 1} = Finch.get_pool_count(finch_name, pool)

    results =
      1..4
      |> Task.async_stream(fn _ -> collect_stream("http://provider.invalid", opts) end)
      |> Enum.to_list()

    assert results == List.duplicate({:ok, "hello"}, 4)
    assert {:ok, ^pid} = Finch.find_pool(finch_name, pool)
  end

  test "map HTTP options use the proxy without changing the direct pool" do
    origin = start_proxy(:origin)
    proxy = start_proxy(:proxy)
    base_url = "http://127.0.0.1:#{origin}"
    opts = [req_http_options: %{connect_options: [proxy: {:http, "127.0.0.1", proxy, []}]}]

    assert collect_stream(base_url, opts) == "hello"
    assert_receive {:proxy_request, :proxy, _, _}
    refute_received {:proxy_request, :origin, _, _}

    assert collect_stream(base_url, []) == "hello"
    assert_receive {:proxy_request, :origin, "POST /v1/chat/completions HTTP/1.1\r\n", _}
    refute_received {:proxy_request, :proxy, _, _}
  end

  test "streams through an HTTP proxy with authentication" do
    port = start_proxy(:http)
    auth = "Basic " <> Base.encode64("proxy-user:proxy-password")

    assert stream_text("http://provider.invalid", port,
             proxy_headers: [{"proxy-authorization", auth}]
           ) ==
             "hello"

    assert_receive {:proxy_request, :http, line, headers}
    assert line == "POST http://provider.invalid/v1/chat/completions HTTP/1.1\r\n"
    assert headers["proxy-authorization"] == auth
  end

  test "streams through an HTTPS CONNECT tunnel with trusted TLS" do
    {tls_options, cacerts} = tls_options()
    port = start_proxy(:https, tls_options: tls_options)
    auth = "Basic " <> Base.encode64("proxy-user:proxy-password")

    assert stream_text("https://provider.invalid", port,
             proxy_headers: [{"proxy-authorization", auth}],
             transport_opts: [cacerts: cacerts]
           ) == "hello"

    assert_receive {:proxy_request, :https, "CONNECT provider.invalid:443 HTTP/1.1\r\n", headers}
    assert headers["proxy-authorization"] == auth
    assert_receive {:tunnel_request, "POST /v1/chat/completions HTTP/1.1\r\n", origin_headers}
    refute Map.has_key?(origin_headers, "proxy-authorization")
  end

  test "keeps different proxies and credentials separate for the same destination" do
    first = start_proxy(:first)
    second = start_proxy(:second)

    assert stream_text("http://provider.invalid", first,
             proxy_headers: [{"proxy-authorization", "first"}]
           ) ==
             "hello"

    assert stream_text("http://provider.invalid", second,
             proxy_headers: [{"proxy-authorization", "second"}]
           ) ==
             "hello"

    assert stream_text("http://provider.invalid", first,
             proxy_headers: [{"proxy-authorization", "third"}]
           ) ==
             "hello"

    assert_receive {:proxy_request, :first, _, %{"proxy-authorization" => "first"}}
    assert_receive {:proxy_request, :second, _, %{"proxy-authorization" => "second"}}
    assert_receive {:proxy_request, :first, _, %{"proxy-authorization" => "third"}}
  end

  test "retries a rate limited request through the same proxy" do
    port = start_proxy(:retry, retry_once: true)

    assert stream_text("http://provider.invalid", port, [], max_retries: 1) == "hello"
    assert_receive {:proxy_request, :retry, _, _}
    assert_receive {:proxy_request, :retry, _, _}
  end

  test "streams directly when no connection options are supplied" do
    port = start_proxy(:direct)

    assert collect_stream("http://127.0.0.1:#{port}", []) == "hello"
    assert_receive {:proxy_request, :direct, "POST /v1/chat/completions HTTP/1.1\r\n", headers}
    refute Map.has_key?(headers, "proxy-authorization")
  end

  test "a failed proxy connection does not send a request directly to the origin" do
    origin = start_proxy(:origin)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    assert_raise ReqLLM.Error.API.Stream, ~r/econnrefused/, fn ->
      stream_text("http://127.0.0.1:#{origin}", port, [])
    end

    refute_received {:proxy_request, :origin, _, _}
  end

  defp stream_text(base_url, port, connection_options, opts \\ []) do
    connection_options = Keyword.put(connection_options, :proxy, {:http, "127.0.0.1", port, []})

    collect_stream(
      base_url,
      Keyword.put(opts, :req_http_options, connect_options: connection_options)
    )
  end

  defp collect_stream(base_url, opts) do
    opts =
      Keyword.merge(
        [
          base_url: base_url <> "/v1",
          api_key: "test-key",
          receive_timeout: 2_000,
          max_retries: 0
        ],
        opts
      )

    assert {:ok, response} =
             ReqLLM.stream_text(%{provider: :openai, id: "proxy-test-model"}, "Hello", opts)

    try do
      StreamResponse.text(response)
    after
      StreamResponse.close(response)
    end
  end

  defp start_proxy(id, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()

    start_supervised!(%{
      id: id,
      start: {Task, :start_link, [fn -> accept_proxy(listener, parent, id, opts, 0) end]}
    })

    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  defp accept_proxy(listener, parent, id, opts, count) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {line, headers} = read_request(socket, :gen_tcp)
        send(parent, {:proxy_request, id, line, headers})
        reply(socket, parent, line, opts, count)
        accept_proxy(listener, parent, id, opts, count + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp reply(socket, parent, "CONNECT " <> _, opts, _count) do
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
    :ok = :inet.setopts(socket, packet: :raw)

    {:ok, tls_socket} =
      :ssl.handshake(socket, opts[:tls_options] ++ [active: false, packet: :line], 3_000)

    {line, headers} = read_request(tls_socket, :ssl)
    send(parent, {:tunnel_request, line, headers})
    send_response(tls_socket, :ssl, 200)
  end

  defp reply(socket, _parent, _line, opts, count) do
    status = if opts[:retry_once] && count == 0, do: 429, else: 200
    send_response(socket, :gen_tcp, status)
  end

  defp read_request(socket, transport) do
    {:ok, line} = transport.recv(socket, 0, 3_000)
    headers = read_headers(socket, transport, %{})
    set_options(socket, transport, packet: :raw)
    length = String.to_integer(Map.get(headers, "content-length", "0"))
    if length > 0, do: transport.recv(socket, length, 3_000)
    {line, headers}
  end

  defp read_headers(socket, transport, headers) do
    case transport.recv(socket, 0, 3_000) do
      {:ok, "\r\n"} ->
        headers

      {:ok, line} ->
        [name, value] = String.split(line, ":", parts: 2)

        read_headers(
          socket,
          transport,
          Map.put(headers, String.downcase(name), String.trim(value))
        )
    end
  end

  defp set_options(socket, :gen_tcp, opts), do: :inet.setopts(socket, opts)
  defp set_options(socket, :ssl, opts), do: :ssl.setopts(socket, opts)

  defp send_response(socket, transport, status) do
    body =
      if status == 200 do
        ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n) <>
          "data: [DONE]\n\n"
      else
        ~s({"error":{"message":"retry"}})
      end

    :ok =
      transport.send(
        socket,
        "HTTP/1.1 #{status} OK\r\ncontent-type: text/event-stream\r\nretry-after: 0\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
          body
      )

    transport.close(socket)
  end

  defp tls_options do
    chain = %{
      root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
      intermediates: [],
      peer: [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"provider.invalid"}]}]
      ]
    }

    data = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})
    {Keyword.take(data[:server_config], [:cert, :key]), data[:client_config][:cacerts]}
  end
end
