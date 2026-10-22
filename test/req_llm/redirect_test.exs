defmodule ReqLLM.RedirectTest do
  use ExUnit.Case, async: true

  defmodule Endpoint do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:owner], {:request, opts[:id], conn.host, conn.req_headers, conn.query_string})

      case opts[:location] do
        nil ->
          body = %{
            id: "msg-test",
            type: "message",
            role: "assistant",
            model: "claude-sonnet-4-5",
            content: [%{type: "text", text: "hello"}],
            stop_reason: "end_turn",
            usage: %{input_tokens: 1, output_tokens: 1}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))

        location ->
          conn
          |> Plug.Conn.put_resp_header("location", location)
          |> Plug.Conn.send_resp(302, "Redirected")
      end
    end
  end

  setup do
    destination = start_endpoint(:destination)
    origin = start_endpoint(:origin, "http://localhost:#{destination}/destination")
    {:ok, base_url: "http://127.0.0.1:#{origin}"}
  end

  for {provider, model, header, extra_opts} <- [
        {:anthropic, "claude-sonnet-4-5", "x-api-key", []},
        {:google, "gemini-2.5-flash", "x-goog-api-key", []},
        {:azure, "gpt-4o", "api-key", [provider_options: [deployment: "test"]]},
        {:azure, "claude-sonnet-4-5", "x-api-key", [provider_options: [deployment: "test"]]}
      ] do
    @tag model_spec: %{provider: provider, id: model},
         auth_header: header,
         extra_opts: extra_opts
    test "#{provider}:#{model} returns a redirect error without forwarding credentials",
         %{
           base_url: base_url
         } = context do
      opts = request_options(base_url) ++ context.extra_opts

      assert {:error, %ReqLLM.Error.API.Request{status: 302, response_body: "Redirected"}} =
               ReqLLM.generate_text(
                 context.model_spec,
                 "Hello",
                 opts
               )

      assert_receive {:request, :origin, "127.0.0.1", headers, query}

      if context.auth_header do
        assert {context.auth_header, "redirect-test-secret"} in headers
      else
        assert URI.decode_query(query)["key"] == "redirect-test-secret"
      end

      refute_received {:request, :destination, _, _, _}
    end
  end

  test "a finite total timeout preserves the redirect default", %{base_url: base_url} do
    assert {:error, %ReqLLM.Error.API.Request{status: 302}} =
             ReqLLM.generate_text(
               %{provider: :anthropic, id: "claude-sonnet-4-5"},
               "Hello",
               request_options(base_url) ++ [total_timeout: 5_000]
             )

    assert_receive {:request, :origin, _, _, _}
    refute_received {:request, :destination, _, _, _}
  end

  test "req_http_options can explicitly enable redirects", %{base_url: base_url} do
    assert {:ok, response} =
             ReqLLM.generate_text(
               %{provider: :anthropic, id: "claude-sonnet-4-5"},
               "Hello",
               request_options(base_url) ++ [req_http_options: [redirect: true]]
             )

    assert ReqLLM.Response.text(response) == "hello"
    assert_receive {:request, :origin, "127.0.0.1", _, _}
    assert_receive {:request, :destination, "localhost", _, _}
  end

  test "file operations do not follow redirects", %{base_url: base_url} do
    assert {:error, %ReqLLM.Error.API.Request{status: 302}} =
             ReqLLM.Providers.OpenAI.Files.list(request_options(base_url))

    assert_receive {:request, :origin, _, _, _}
    refute_received {:request, :destination, _, _, _}
  end

  test "cached content operations do not follow redirects", %{base_url: base_url} do
    assert {:error, reason} =
             ReqLLM.Providers.Google.CachedContent.list(
               request_options(base_url) ++ [provider: :google]
             )

    assert reason =~ "302"
    assert_receive {:request, :origin, _, _, _}
    refute_received {:request, :destination, _, _, _}
  end

  test "cached content operations honor an explicit redirect option", %{base_url: base_url} do
    assert {:ok, _response} =
             ReqLLM.Providers.Google.CachedContent.list(
               request_options(base_url) ++
                 [provider: :google, req_http_options: [redirect: true]]
             )

    assert_receive {:request, :origin, "127.0.0.1", _, _}
    assert_receive {:request, :destination, "localhost", _, _}
  end

  for provider <- [ReqLLM.Providers.OpenAI.OAuth, ReqLLM.Providers.Anthropic.OAuth] do
    test "#{provider} does not follow redirects", %{base_url: base_url} do
      assert {:error, reason} =
               unquote(provider).refresh(%{refresh: "test-refresh-token"},
                 oauth_http_options: [url: base_url]
               )

      assert reason =~ "302"
      assert_receive {:request, :origin, _, _, _}
      refute_received {:request, :destination, _, _, _}
    end
  end

  defp request_options(base_url) do
    [
      base_url: base_url,
      api_key: "redirect-test-secret",
      receive_timeout: 5_000,
      max_retries: 0
    ]
  end

  defp start_endpoint(id, location \\ nil) do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {Endpoint, owner: self(), id: id, location: location},
           port: 0,
           ip: {127, 0, 0, 1},
           startup_log: false},
          id: id
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end
end
