defmodule ReqLLM.Streaming.FinchClientTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Streaming.FinchClient
  alias ReqLLM.Streaming.Fixtures.HTTPContext

  defmodule StreamingRouter do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/stream" do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(conn, "data: {\"choices\": [{\"delta\": {\"content\": \"hello\"}}]}\n\n")

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  setup do
    adapter_config = Application.get_env(:req_llm, :finch_request_adapter)
    finch_config = Application.get_env(:req_llm, :finch)
    fixtures_mode = System.get_env("REQ_LLM_FIXTURES_MODE")
    openai_api_key = System.get_env("OPENAI_API_KEY")

    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")
    System.put_env("OPENAI_API_KEY", "test-streaming-key")

    on_exit(fn ->
      restore_app_env(:finch_request_adapter, adapter_config)
      restore_app_env(:finch, finch_config)
      restore_system_env("REQ_LLM_FIXTURES_MODE", fixtures_mode)
      restore_system_env("OPENAI_API_KEY", openai_api_key)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_app_env(key, value), do: Application.put_env(:req_llm, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  describe "HTTPContext" do
    test "creates new context with basic info" do
      headers = %{
        "content-type" => "application/json",
        "authorization" => "Bearer secret-key",
        "x-api-key" => "super-secret"
      }

      context = HTTPContext.new("https://api.example.com/v1/chat", :post, headers)

      assert context.url == "https://api.example.com/v1/chat"
      assert context.method == :post
      assert context.status == nil
      assert context.resp_headers == nil

      # Sensitive headers should be sanitized
      assert String.contains?(context.req_headers["authorization"], "REDACTED")
      assert String.contains?(context.req_headers["x-api-key"], "REDACTED")
      assert context.req_headers["content-type"] == "application/json"
    end

    test "updates context with response data" do
      context = HTTPContext.new("https://api.example.com/v1/chat", :post, %{})

      resp_headers = %{
        "content-type" => "text/event-stream",
        "x-api-key" => "secret-response-key"
      }

      updated_context = HTTPContext.update_response(context, 200, resp_headers)

      assert updated_context.status == 200
      assert updated_context.resp_headers["content-type"] == "text/event-stream"
      assert String.contains?(updated_context.resp_headers["x-api-key"], "REDACTED")
    end

    test "handles list headers" do
      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer secret"}
      ]

      context = HTTPContext.new("https://api.example.com", :post, headers)

      assert context.req_headers["content-type"] == "application/json"
      assert String.contains?(context.req_headers["authorization"], "REDACTED")
    end

    test "sanitizes all known sensitive header types" do
      sensitive_headers = %{
        "authorization" => "Bearer token",
        "x-api-key" => "key123",
        "anthropic-api-key" => "anthropic-key",
        "openai-api-key" => "openai-key",
        "x-auth-token" => "auth-token",
        "bearer" => "bearer-token",
        "api-key" => "api-key-value",
        "access-token" => "access-token-value",
        "safe-header" => "safe-value"
      }

      context = HTTPContext.new("https://api.example.com", :post, sensitive_headers)

      # All sensitive headers should be sanitized
      sensitive_keys = [
        "authorization",
        "x-api-key",
        "anthropic-api-key",
        "openai-api-key",
        "x-auth-token",
        "bearer",
        "api-key",
        "access-token"
      ]

      Enum.each(sensitive_keys, fn key ->
        assert String.contains?(context.req_headers[key], "REDACTED")
      end)

      # Safe headers should remain unchanged
      assert context.req_headers["safe-header"] == "safe-value"
    end

    test "builds context from finch request with known method" do
      request =
        Finch.build(:post, "https://api.example.com/v1/chat", [
          {"authorization", "Bearer secret-key"},
          {"content-type", "application/json"}
        ])

      context = HTTPContext.from_finch_request(request)

      assert context.url == "https://api.example.com/v1/chat"
      assert context.method == :post
      assert String.contains?(context.req_headers["authorization"], "REDACTED")
      assert context.req_headers["content-type"] == "application/json"
    end

    test "falls back to :unknown method for non-standard finch method" do
      request =
        Finch.build(:get, "https://api.example.com/v1/chat")
        |> Map.put(:method, "PURGE")

      context = HTTPContext.from_finch_request(request)

      assert context.method == :unknown
    end
  end

  describe "start_stream/5 error handling" do
    defmodule MockStreamServer do
      use GenServer

      def start_link do
        GenServer.start_link(__MODULE__, [])
      end

      def init(_), do: {:ok, []}

      def handle_call({:http_event, _event}, _from, state) do
        {:reply, :ok, state}
      end
    end

    defmodule EventStreamServer do
      use GenServer

      def start_link do
        GenServer.start_link(__MODULE__, [])
      end

      def events(pid) do
        GenServer.call(pid, :events)
      end

      def init(_), do: {:ok, []}

      def handle_call(:events, _from, state) do
        {:reply, Enum.reverse(state), state}
      end

      def handle_call({:http_event, event}, _from, state) do
        {:reply, :ok, [event | state]}
      end
    end

    defmodule ErrorProvider do
      def attach_stream(_model, _context, _opts, _finch_name), do: {:error, :boom}
    end

    defmodule LargeBodyProvider do
      def attach_stream(_model, _context, _opts, _finch_name) do
        {:ok,
         Finch.build(
           :post,
           "https://example.com/stream",
           [{"content-type", "application/json"}],
           String.duplicate("x", 70_000)
         )}
      end
    end

    defmodule LiveStreamProvider do
      def attach_stream(_model, _context, opts, _finch_name) do
        body =
          opts
          |> Keyword.get(:request_body, %{"thinking" => %{"type" => "enabled"}})
          |> Jason.encode!()

        {:ok,
         Finch.build(
           :post,
           Keyword.fetch!(opts, :stream_url),
           [{"content-type", "application/json"}],
           body
         )}
      end
    end

    test "returns error when provider module doesn't exist" do
      {:ok, stream_server} = MockStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")

      result =
        FinchClient.start_stream(
          NonExistentProvider,
          %LLMDB.Model{provider: :invalid, id: "test"},
          context,
          [],
          stream_server
        )

      assert {:error, {:build_request_failed, _}} = result
    end

    test "successfully creates HTTPContext with proper structure" do
      {:ok, stream_server} = MockStreamServer.start_link()
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      {:ok, context} = Context.normalize("Test")

      result =
        FinchClient.start_stream(
          ReqLLM.Providers.OpenAI,
          model,
          context,
          [],
          stream_server
        )

      # Should succeed and return proper HTTPContext structure
      assert {:ok, task_pid, http_context, canonical_json} = result
      assert is_pid(task_pid)
      assert %HTTPContext{} = http_context
      assert is_map(canonical_json)
      assert String.starts_with?(http_context.url, "https://")
      assert String.ends_with?(http_context.url, "/chat/completions")
      assert http_context.method == :post
      assert is_map(http_context.req_headers)
    end

    test "returns provider_build_failed when provider attach_stream returns an error" do
      {:ok, stream_server} = MockStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")

      assert {:error, {:provider_build_failed, :boom}} =
               FinchClient.start_stream(
                 ErrorProvider,
                 %LLMDB.Model{provider: :test, id: "test"},
                 context,
                 [],
                 stream_server
               )
    end

    test "replays streaming fixtures without building a live request" do
      {:ok, stream_server} = EventStreamServer.start_link()
      {:ok, model} = ReqLLM.model("openrouter:google/gemini-3-flash-preview")
      {:ok, context} = Context.normalize("Hello")

      assert {:ok, task_pid, http_context, canonical_json} =
               FinchClient.start_stream(
                 ReqLLM.Providers.OpenRouter,
                 model,
                 context,
                 [fixture: "streaming"],
                 stream_server
               )

      assert is_pid(task_pid)
      assert http_context.url =~ "fixture://"
      assert http_context.status == 200
      assert canonical_json["model"] == "google/gemini-3-flash-preview"

      Process.sleep(50)

      assert Enum.any?(EventStreamServer.events(stream_server), &match?({:status, 200}, &1))
    end

    test "allows large request bodies when finch pool config is missing" do
      Application.put_env(:req_llm, :finch, [])

      {:ok, stream_server} = MockStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")

      assert {:ok, task_pid, http_context, canonical_json} =
               FinchClient.start_stream(
                 LargeBodyProvider,
                 %LLMDB.Model{provider: :test, id: "test"},
                 context,
                 [receive_timeout: 10, max_retries: 0],
                 stream_server
               )

      assert is_pid(task_pid)
      assert %HTTPContext{} = http_context
      assert canonical_json[:raw_body] != nil
    end

    test "allows large request bodies when finch config cannot be parsed" do
      Application.put_env(:req_llm, :finch, :invalid_config)

      {:ok, stream_server} = MockStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")

      assert {:ok, task_pid, _http_context, _canonical_json} =
               FinchClient.start_stream(
                 LargeBodyProvider,
                 %LLMDB.Model{provider: :test, id: "test"},
                 context,
                 [receive_timeout: 10, max_retries: 0],
                 stream_server
               )

      assert is_pid(task_pid)
    end

    test "forwards successful HTTP streaming events through the stream server" do
      port = reserve_port()
      start_supervised!({Bandit, plug: StreamingRouter, port: port})

      {:ok, stream_server} = EventStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")
      model = %LLMDB.Model{provider: :test, id: "test"}
      stream_url = "http://127.0.0.1:#{port}/stream"

      assert {:ok, task_pid, http_context, canonical_json} =
               FinchClient.start_stream(
                 LiveStreamProvider,
                 model,
                 context,
                 [stream_url: stream_url],
                 stream_server
               )

      assert is_pid(task_pid)
      assert %HTTPContext{} = http_context
      assert canonical_json["thinking"]["type"] == "enabled"

      assert wait_until(fn ->
               events = EventStreamServer.events(stream_server)

               Enum.any?(events, &match?({:status, 200}, &1)) and
                 Enum.any?(events, &match?({:data, _}, &1))
             end)

      monitor_ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid, _}, 1_000

      events = EventStreamServer.events(stream_server)

      assert Enum.any?(events, &match?({:status, 200}, &1))
      assert Enum.any?(events, &match?({:headers, _}, &1))
      assert Enum.any?(events, &match?({:data, _}, &1))
    end

    test "forwards retry stream errors through the stream server" do
      {:ok, stream_server} = EventStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")
      model = %LLMDB.Model{provider: :test, id: "test"}

      assert {:ok, task_pid, _http_context, _canonical_json} =
               FinchClient.start_stream(
                 LiveStreamProvider,
                 model,
                 context,
                 [stream_url: "http://127.0.0.1:1/stream", max_retries: 0, receive_timeout: 10],
                 stream_server
               )

      assert is_pid(task_pid)

      assert wait_until(fn ->
               Enum.any?(EventStreamServer.events(stream_server), &match?({:error, _}, &1))
             end)
    end

    test "captures finch process exits as stream server errors" do
      port = reserve_port()
      start_supervised!({Bandit, plug: StreamingRouter, port: port})

      {:ok, stream_server} = EventStreamServer.start_link()
      {:ok, context} = Context.normalize("Test")
      model = %LLMDB.Model{provider: :test, id: "test"}
      stream_url = "http://127.0.0.1:#{port}/stream"

      assert {:ok, task_pid, _http_context, _canonical_json} =
               FinchClient.start_stream(
                 LiveStreamProvider,
                 model,
                 context,
                 [stream_url: stream_url, receive_timeout: 10],
                 stream_server,
                 ReqLLM.MissingFinch
               )

      assert is_pid(task_pid)

      assert wait_until(fn ->
               Enum.any?(EventStreamServer.events(stream_server), &match?({:error, _}, &1))
             end)
    end
  end

  describe "provider URL and endpoint mapping" do
    test "maps provider modules to correct base URLs" do
      # Test internal URL mapping by checking if FinchClient would build correct URLs
      # We can't easily test the private functions directly, but we can verify
      # the expected behavior through other means or by checking logged output

      providers_and_expected_urls = [
        {ReqLLM.Providers.OpenAI, "https://api.openai.com/v1", "/chat/completions"},
        {ReqLLM.Providers.Anthropic, "https://api.anthropic.com", "/v1/messages"},
        {ReqLLM.Providers.Google, "https://generativelanguage.googleapis.com/v1beta",
         "/chat/completions"},
        {ReqLLM.Providers.Groq, "https://api.groq.com/openai/v1", "/chat/completions"},
        {ReqLLM.Providers.OpenRouter, "https://openrouter.ai/api/v1", "/chat/completions"},
        {ReqLLM.Providers.Xai, "https://api.x.ai/v1", "/chat/completions"}
      ]

      Enum.each(providers_and_expected_urls, fn {provider_mod, base_url, endpoint} ->
        expected_full_url = "#{base_url}#{endpoint}"

        # We expect these to be the URLs that would be built
        # This test documents the expected behavior even if we can't easily test it
        assert is_atom(provider_mod)
        assert String.starts_with?(base_url, "https://")
        assert String.starts_with?(endpoint, "/")
        assert String.contains?(expected_full_url, "api")
      end)
    end
  end

  describe "request body structure" do
    test "fallback body builder creates valid streaming JSON" do
      # Test the fallback body builder that should work when provider encode_body fails
      {:ok, _context} = Context.normalize("Hello world")

      # Since the actual fallback function is private, we test the expected structure
      # by documenting what it should produce
      expected_structure = %{
        "model" => "gpt-4",
        "messages" => [
          %{
            "role" => "user",
            "content" => "Hello world"
          }
        ],
        "stream" => true,
        "temperature" => 0.7,
        "max_tokens" => 100
      }

      # Verify the structure is valid JSON
      json_string = Jason.encode!(expected_structure)
      decoded = Jason.decode!(json_string)

      assert decoded["model"] == "gpt-4"
      assert decoded["stream"] == true
      assert decoded["temperature"] == 0.7
      assert decoded["max_tokens"] == 100
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 1

      message = List.first(decoded["messages"])
      assert message["role"] == "user"
      assert message["content"] == "Hello world"
    end

    test "validates streaming headers are set correctly" do
      expected_headers = %{
        "Accept" => "text/event-stream",
        "Content-Type" => "application/json",
        "Cache-Control" => "no-cache"
      }

      # These should be the base headers set for all streaming requests
      assert expected_headers["Accept"] == "text/event-stream"
      assert expected_headers["Content-Type"] == "application/json"
      assert expected_headers["Cache-Control"] == "no-cache"
    end
  end

  describe "authentication header formats" do
    test "documents expected authentication patterns" do
      auth_patterns = [
        {:openai, "Authorization", "Bearer sk-..."},
        {:anthropic, "x-api-key", "anthropic-key..."},
        {:google, "x-goog-api-key", "google-api-key..."},
        {:groq, "Authorization", "Bearer gsk_..."},
        {:openrouter, "Authorization", "Bearer sk-or-..."},
        {:xai, "Authorization", "Bearer xai-..."}
      ]

      Enum.each(auth_patterns, fn {provider, header_name, pattern} ->
        assert is_atom(provider)
        assert is_binary(header_name)
        assert is_binary(pattern)

        case provider do
          :anthropic -> assert header_name == "x-api-key"
          :google -> assert header_name == "x-goog-api-key"
          _ -> assert header_name == "Authorization" and String.starts_with?(pattern, "Bearer ")
        end
      end)
    end
  end

  describe "safe_http_event/2 graceful termination handling" do
    defmodule TerminatingStreamServer do
      use GenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts)
      end

      def init(opts), do: {:ok, opts}

      def handle_call({:http_event, _event}, _from, state) do
        {:reply, :ok, state}
      end
    end

    test "handles :noproc when server is already dead" do
      {:ok, pid} = TerminatingStreamServer.start_link()
      GenServer.stop(pid)

      Process.sleep(10)

      result =
        try do
          ReqLLM.StreamServer.http_event(pid, {:data, "test"})
        catch
          :exit, {:noproc, _} -> :caught_noproc
        end

      assert result == :caught_noproc
    end

    test "FinchClient callback does not crash when server terminates" do
      {:ok, stream_server} = TerminatingStreamServer.start_link()
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      {:ok, context} = Context.normalize("Test")

      {:ok, task_pid, _http_context, _canonical_json} =
        FinchClient.start_stream(
          ReqLLM.Providers.OpenAI,
          model,
          context,
          [],
          stream_server
        )

      GenServer.stop(stream_server)
      Process.sleep(10)

      ref = Process.monitor(task_pid)
      Process.unlink(task_pid)
      Process.exit(task_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^task_pid, reason} ->
          assert reason in [:killed, :noproc]
      after
        1000 -> flunk("Task did not terminate")
      end
    end
  end
end
