defmodule ReqLLM.Providers.Google.InteractionsAPI.LifecycleTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Google.InteractionsAPIHelpers, only: [inline_json_plug: 1]

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Error.API.Timeout, as: TimeoutError
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.Google.InteractionsAPI

  defmodule SecretLeakAdapter do
    @moduledoc false

    def run(req) do
      {req,
       RuntimeError.exception(
         "connection failed to https://example.test/v1?key=secret_leaked_999"
       )}
    end
  end

  defmodule LeakAdapter do
    @moduledoc false

    def run(req) do
      {req,
       %RuntimeError{
         message: "Failed calling https://example.com/v1/interactions?key=secret_key_42"
       }}
    end
  end

  defmodule MintRetryAdapter do
    @moduledoc false

    def run(req) do
      agent = Process.get(:interactions_mint_attempts_agent)
      attempt = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)

      if attempt == 1 do
        {req, %Mint.TransportError{reason: :timeout}}
      else
        resp =
          Req.Response.new(
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: %{"id" => "int_mint_ok", "status" => "completed", "steps" => []}
          )

        {req, resp}
      end
    end
  end

  @api_key "test-google-key"

  describe "lifecycle helpers get/2, cancel/2, delete/2, and wait/2" do
    test "executes get/2, cancel/2, delete/2, and wait/2 with query auth, escaping, retries, and timeout" do
      parent = self()
      attempt_counter = :counters.new(1, [])

      lifecycle_plug =
        inline_json_plug(fn %{conn: conn} ->
          send(
            parent,
            {:lifecycle_http, conn.method, conn.request_path, conn.query_params, conn.req_headers}
          )

          case {conn.method, conn.request_path} do
            {"GET", "/v1beta/interactions/int_agent"} ->
              {200,
               %{
                 "id" => "int_agent",
                 "status" => "completed",
                 "steps" => [
                   %{
                     "type" => "model_output",
                     "content" => [%{"type" => "text", "text" => "Done"}]
                   }
                 ]
               }}

            {"GET", "/v1/interactions/bad%2Fid%3Fx%3D1"} ->
              {200, %{"id" => "bad/id?x=1", "status" => "completed", "steps" => []}}

            {"POST", "/v1/interactions/int_job/cancel"} ->
              {200, %{"id" => "int_job", "status" => "cancelled", "steps" => []}}

            {"DELETE", "/v1/interactions/int_job"} ->
              {200, %{}}

            {"GET", "/v1/interactions/int_poll"} ->
              n = :counters.get(attempt_counter, 1) + 1
              :counters.put(attempt_counter, 1, n)

              case n do
                1 -> {503, %{"error" => %{"message" => "Temporary unavailable"}}}
                2 -> {200, %{"id" => "int_poll", "status" => "in_progress", "steps" => []}}
                3 -> {503, %{"error" => %{"message" => "Temporary unavailable again"}}}
                _ -> {200, %{"id" => "int_poll", "status" => "completed", "steps" => []}}
              end

            {"GET", "/v1/interactions/int_slow"} ->
              {200, %{"id" => "int_slow", "status" => "in_progress", "steps" => []}}
          end
        end)

      common_opts = [api_key: @api_key, req_http_options: [plug: lifecycle_plug]]

      {:ok, got} =
        InteractionsAPI.get(
          "int_agent",
          common_opts ++
            [google_api_version: "v1beta", provider_options: [google_auth_header: false]]
        )

      assert_receive {:lifecycle_http, "GET", "/v1beta/interactions/int_agent",
                      %{"key" => @api_key}, get_headers}

      assert {"api-revision", "2026-05-20"} in get_headers
      refute Enum.any?(get_headers, fn {k, _} -> k == "x-goog-api-key" end)
      assert ReqLLM.Response.text(got) == "Done"

      {:ok, escaped} = InteractionsAPI.get("bad/id?x=1", common_opts)
      assert_receive {:lifecycle_http, "GET", "/v1/interactions/bad%2Fid%3Fx%3D1", _, _}
      assert escaped.id == "bad/id?x=1"

      {:ok, cancelled} = InteractionsAPI.cancel("int_job", common_opts)
      assert_receive {:lifecycle_http, "POST", "/v1/interactions/int_job/cancel", _, _}
      assert cancelled.finish_reason == :cancelled

      assert :ok = InteractionsAPI.delete("int_job", common_opts)
      assert_receive {:lifecycle_http, "DELETE", "/v1/interactions/int_job", _, _}

      {:ok, waited} =
        InteractionsAPI.wait(
          "int_poll",
          common_opts ++ [poll_interval: 1, timeout: 1_000, max_transient_retries: 1]
        )

      assert waited.finish_reason == :stop
      assert :counters.get(attempt_counter, 1) == 4

      assert {:error, %TimeoutError{}} =
               InteractionsAPI.wait(
                 "int_slow",
                 common_opts ++ [poll_interval: 25, timeout: 20]
               )

      assert {:error, %Parameter{}} = InteractionsAPI.get("int_missing_key", api_key: "")
      assert {:error, %Parameter{}} = InteractionsAPI.stream("", api_key: @api_key)
      assert {:error, %Parameter{}} = InteractionsAPI.stream("   ", api_key: @api_key)
    end

    test "supports ReqLLM.Response structs in get/2, cancel/2, and delete/2" do
      parent = self()

      lifecycle_plug =
        inline_json_plug(fn %{conn: conn} ->
          send(parent, {:resp_lifecycle_http, conn.method, conn.request_path})

          case {conn.method, conn.request_path} do
            {"GET", "/v1/interactions/int_resp_1"} ->
              {200,
               %{
                 "id" => "int_resp_1",
                 "model" => "gemini-4-hydrogen",
                 "status" => "completed",
                 "steps" => [
                   %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "OK"}]}
                 ]
               }}

            {"POST", "/v1/interactions/int_resp_1/cancel"} ->
              {200, %{"id" => "int_resp_1", "status" => "cancelled", "steps" => []}}

            {"DELETE", "/v1/interactions/int_resp_1"} ->
              {200, %{}}

            {"GET", "/v1beta/interactions/int_agent_resp"} ->
              {200,
               %{
                 "id" => "int_agent_resp",
                 "agent" => "deep-research-pro",
                 "status" => "completed",
                 "steps" => []
               }}

            {"POST", "/v1beta/interactions/int_agent_resp/cancel"} ->
              {200,
               %{
                 "id" => "int_agent_resp",
                 "agent" => "deep-research-pro",
                 "status" => "cancelled",
                 "steps" => []
               }}

            {"DELETE", "/v1beta/interactions/int_agent_resp"} ->
              {200, %{}}
          end
        end)

      common_opts = [api_key: @api_key, req_http_options: [plug: lifecycle_plug]]

      model_resp = %ReqLLM.Response{
        id: "int_resp_1",
        model: "gemini-4-hydrogen",
        context: %Context{},
        provider_meta: %{}
      }

      assert {:ok, %ReqLLM.Response{id: "int_resp_1", model: "gemini-4-hydrogen"}} =
               InteractionsAPI.get(model_resp, common_opts)

      assert_receive {:resp_lifecycle_http, "GET", "/v1/interactions/int_resp_1"}

      assert {:ok, %ReqLLM.Response{finish_reason: :cancelled}} =
               InteractionsAPI.cancel(model_resp, common_opts)

      assert_receive {:resp_lifecycle_http, "POST", "/v1/interactions/int_resp_1/cancel"}

      assert :ok = InteractionsAPI.delete(model_resp, common_opts)
      assert_receive {:resp_lifecycle_http, "DELETE", "/v1/interactions/int_resp_1"}

      agent_resp = %ReqLLM.Response{
        id: "int_agent_resp",
        model: "deep-research-pro",
        context: %Context{},
        provider_meta: %{"agent" => "deep-research-pro"}
      }

      assert {:ok, %ReqLLM.Response{id: "int_agent_resp"}} =
               InteractionsAPI.get(agent_resp, common_opts)

      assert_receive {:resp_lifecycle_http, "GET", "/v1beta/interactions/int_agent_resp"}

      assert {:ok, %ReqLLM.Response{finish_reason: :cancelled}} =
               InteractionsAPI.cancel(agent_resp, common_opts)

      assert_receive {:resp_lifecycle_http, "POST", "/v1beta/interactions/int_agent_resp/cancel"}

      assert :ok = InteractionsAPI.delete(agent_resp, common_opts)
      assert_receive {:resp_lifecycle_http, "DELETE", "/v1beta/interactions/int_agent_resp"}

      empty_id_resp = %ReqLLM.Response{
        id: nil,
        model: "gemini-4-hydrogen",
        context: %Context{}
      }

      assert {:error, %Parameter{}} = InteractionsAPI.get(empty_id_resp, common_opts)
      assert {:error, %Parameter{}} = InteractionsAPI.cancel(empty_id_resp, common_opts)
      assert {:error, %Parameter{}} = InteractionsAPI.delete(empty_id_resp, common_opts)
    end

    test "routes v1beta lifecycle ops for v1beta_ prefixes, 404 fallback, and agent responses" do
      test_pid = self()

      agent_lifecycle_plug = fn conn ->
        send(test_pid, {:agent_route, conn.method, conn.request_path})

        case conn.request_path do
          "/v1/interactions/int_agent_404" ->
            Plug.Conn.send_resp(
              conn,
              404,
              Jason.encode!(%{"error" => %{"message" => "Not found"}})
            )

          "/v1beta/interactions/int_agent_404" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{
                "id" => "int_agent_404",
                "agent" => "deep-research-pro-preview-12-2025",
                "status" => "completed",
                "steps" => [
                  %{
                    "type" => "model_output",
                    "content" => [%{"type" => "text", "text" => "Beta fallback"}]
                  }
                ]
              })
            )

          "/v1beta/interactions/v1beta_job_1" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{
                "id" => "v1beta_job_1",
                "status" => "completed",
                "steps" => [
                  %{
                    "type" => "model_output",
                    "content" => [%{"type" => "text", "text" => "Prefixed"}]
                  }
                ]
              })
            )

          "/v1beta/interactions/int_agent_resp" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{
                "id" => "int_agent_resp",
                "agent" => "deep-research-pro-preview-12-2025",
                "status" => "completed",
                "steps" => []
              })
            )
        end
      end

      plug_opts = [api_key: @api_key, req_http_options: [plug: agent_lifecycle_plug]]

      {:ok, prefixed} = InteractionsAPI.get("v1beta_job_1", plug_opts)
      assert_receive {:agent_route, "GET", "/v1beta/interactions/v1beta_job_1"}
      assert ReqLLM.Response.text(prefixed) == "Prefixed"

      {:ok, fallback_404} = InteractionsAPI.get("int_agent_404", plug_opts)
      assert_receive {:agent_route, "GET", "/v1/interactions/int_agent_404"}
      assert_receive {:agent_route, "GET", "/v1beta/interactions/int_agent_404"}
      assert ReqLLM.Response.text(fallback_404) == "Beta fallback"

      {:ok, waited_resp} =
        InteractionsAPI.wait(fallback_404, Keyword.put(plug_opts, :poll_interval, 1))

      assert waited_resp.id == "int_agent_404"

      {:ok, resp_struct} =
        InteractionsAPI.wait(
          %ReqLLM.Response{
            id: "int_agent_resp",
            model: "deep-research-pro-preview-12-2025",
            context: Context.new([]),
            provider_meta: %{"agent" => "deep-research-pro-preview-12-2025"}
          },
          plug_opts
        )

      assert_receive {:agent_route, "GET", "/v1beta/interactions/int_agent_resp"}
      assert resp_struct.id == "int_agent_resp"
    end
  end

  describe "headers, errors, telemetry, and transient retries" do
    test "preserves lifecycle headers/params, resolves response model, handles wait failures, and redacts RequestError secrets" do
      test_pid = self()

      lifecycle_plug = fn conn ->
        send(
          test_pid,
          {:plug_req, conn.method, conn.request_path, conn.query_string, conn.req_headers}
        )

        case conn.request_path do
          "/v1/interactions/int_headers" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{
                "id" => "int_headers",
                "model" => "gemini-2.5-flash",
                "status" => "completed",
                "steps" => [
                  %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "OK"}]}
                ],
                "usage" => %{"total_input_tokens" => 10, "total_output_tokens" => 5}
              })
            )

          "/v1/interactions/int_failed" ->
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{
                "id" => "int_failed",
                "status" => "failed",
                "error" => %{"message" => "Backend crashed"}
              })
            )
        end
      end

      {:ok, got} =
        InteractionsAPI.get("int_headers",
          api_key: "secret_token_abc",
          provider_options: [google_auth_header: false],
          req_http_options: [
            plug: lifecycle_plug,
            headers: [{"X-Request-Id", "req-99"}],
            params: [alt: "json"]
          ]
        )

      assert_receive {:plug_req, "GET", "/v1/interactions/int_headers", query, req_headers}
      decoded_query = URI.decode_query(query)
      assert decoded_query == %{"alt" => "json", "key" => "secret_token_abc"}
      assert {"api-revision", "2026-05-20"} in req_headers
      assert {"accept", "application/json"} in req_headers
      assert {"x-request-id", "req-99"} in req_headers
      assert got.model == "gemini-2.5-flash"

      {:ok, failed_get} =
        InteractionsAPI.get("int_failed",
          api_key: @api_key,
          req_http_options: [plug: lifecycle_plug]
        )

      assert failed_get.finish_reason == :error
      assert %ResponseError{reason: "Backend crashed"} = failed_get.error

      assert {:error, %ResponseError{reason: "Backend crashed"}} =
               InteractionsAPI.wait("int_failed",
                 api_key: @api_key,
                 poll_interval: 1,
                 req_http_options: [plug: lifecycle_plug]
               )

      assert {:error, %Parameter{}} =
               InteractionsAPI.wait("int_failed", api_key: @api_key, poll_interval: 0)

      assert {:error, %ReqLLM.Error.API.Request{reason: err_reason}} =
               InteractionsAPI.get("int_err_transport",
                 api_key: "secret_leaked_999",
                 provider_options: [google_auth_header: false],
                 req_http_options: [adapter: SecretLeakAdapter, retry: false]
               )

      assert err_reason =~ "key=[REDACTED]"
      refute err_reason =~ "secret_leaked_999"
    end

    test "validates wait/2 options, clamps receive_timeout, tags lifecycle telemetry, and redacts non-RequestError secrets" do
      test_pid = self()

      assert {:error, %Parameter{}} =
               InteractionsAPI.wait("int_1", api_key: @api_key, timeout: -1)

      assert {:error, %Parameter{}} =
               InteractionsAPI.wait("int_1", api_key: @api_key, max_transient_retries: -1)

      handler_id = {:interactions_lifecycle_telemetry, make_ref()}

      :telemetry.attach(
        handler_id,
        [:req_llm, :request, :stop],
        fn _event, _meas, meta, pid -> send(pid, {:telemetry_op, meta.operation}) end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      plug = fn conn ->
        send(test_pid, {:poll_opts, conn.method, conn.request_path})

        Req.Test.json(%{conn | status: 200}, %{
          "id" => "int_t",
          "status" => "completed",
          "steps" => []
        })
      end

      {:ok, _} =
        InteractionsAPI.wait("int_t",
          api_key: @api_key,
          timeout: 500,
          req_http_options: [plug: plug, receive_timeout: 60_000]
        )

      assert_receive {:telemetry_op, :interactions_get}

      {:ok, _} =
        InteractionsAPI.cancel("int_t", api_key: @api_key, req_http_options: [plug: plug])

      assert_receive {:telemetry_op, :interactions_cancel}

      :ok = InteractionsAPI.delete("int_t", api_key: @api_key, req_http_options: [plug: plug])
      assert_receive {:telemetry_op, :interactions_delete}

      {:error, err} =
        InteractionsAPI.get("int_leak",
          api_key: "secret_key_42",
          req_http_options: [adapter: LeakAdapter, retry: false]
        )

      refute inspect(err) =~ "secret_key_42"
      assert inspect(err) =~ "key=[REDACTED]"
    end

    test "wait/2 retries Req.TransportError and unwraps background :object responses on wait" do
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      transport_plug = fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(test_pid, {:transport_attempt, attempt})

        if attempt == 1 do
          Req.Test.transport_error(conn, :closed)
        else
          Req.Test.json(%{conn | status: 200}, %{
            "id" => "int_bg_obj",
            "status" => "completed",
            "response_format" => %{
              "type" => "text",
              "mime_type" => "application/json",
              "schema" => %{"type" => "object"}
            },
            "steps" => [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => ~s({"answer":42})}]
              }
            ]
          })
        end
      end

      assert {:ok, bg_resp} =
               InteractionsAPI.wait("int_bg_obj",
                 api_key: @api_key,
                 poll_interval: 1,
                 max_transient_retries: 2,
                 req_http_options: [plug: transport_plug]
               )

      assert_receive {:transport_attempt, 1}
      assert_receive {:transport_attempt, 2}
      assert bg_resp.object == %{"answer" => 42}
    end

    test "wait/2 retries %Mint.TransportError{} returned from adapter" do
      {:ok, mint_attempts} = Agent.start_link(fn -> 0 end)
      Process.put(:interactions_mint_attempts_agent, mint_attempts)
      on_exit(fn -> Process.delete(:interactions_mint_attempts_agent) end)

      assert {:ok, resp} =
               InteractionsAPI.wait("int_mint_ok",
                 api_key: @api_key,
                 poll_interval: 1,
                 max_transient_retries: 2,
                 req_http_options: [adapter: MintRetryAdapter]
               )

      assert resp.id == "int_mint_ok"
      assert Agent.get(mint_attempts, & &1) == 2
    end
  end
end
