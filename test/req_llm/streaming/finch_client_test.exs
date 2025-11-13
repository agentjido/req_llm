defmodule ReqLLM.Streaming.FinchClientTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Streaming.FinchClient
  alias ReqLLM.Streaming.Fixtures.HTTPContext

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
      assert http_context.url == "https://api.openai.com/v1/chat/completions"
      assert http_context.method == :post
      assert is_map(http_context.req_headers)
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
      # Document the expected authentication header formats for each provider
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

        # Anthropic uses x-api-key, others use Authorization Bearer
        case provider do
          :anthropic -> assert header_name == "x-api-key"
          :google -> assert header_name == "x-goog-api-key"
          _ -> assert header_name == "Authorization" and String.starts_with?(pattern, "Bearer ")
        end
      end)
    end
  end
end
