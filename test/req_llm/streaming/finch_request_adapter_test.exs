defmodule ReqLLM.Streaming.FinchRequestAdapterTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Streaming.FinchClient

  # Minimal GenServer that absorbs http_event calls so FinchClient.start_stream
  # doesn't block or crash waiting for a real StreamServer.
  defmodule SinkStreamServer do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])
    def init(_), do: {:ok, []}
    def handle_call({:http_event, _event}, _from, state), do: {:reply, :ok, state}
  end

  defmodule TraceHeaderAdapter do
    @behaviour ReqLLM.FinchRequestAdapter

    @impl true
    def call(%Finch.Request{} = request) do
      %{request | headers: request.headers ++ [{"x-adapter-trace", "applied"}]}
    end
  end

  setup do
    adapter_config = Application.get_env(:req_llm, :finch_request_adapter)
    on_exit(fn -> Application.put_env(:req_llm, :finch_request_adapter, adapter_config) end)
    :ok
  end

  defp build_stream(opts \\ []) do
    {:ok, server} = SinkStreamServer.start_link()
    {:ok, model} = ReqLLM.model("openai:gpt-4")
    {:ok, context} = Context.normalize("Hello")
    FinchClient.start_stream(ReqLLM.Providers.OpenAI, model, context, opts, server)
  end

  describe "config-level finch_request_adapter" do
    test "adapter is called and its header changes appear in the built request" do
      Application.put_env(:req_llm, :finch_request_adapter, TraceHeaderAdapter)

      assert {:ok, _task, http_context, _json} = build_stream()
      assert http_context.req_headers["x-adapter-trace"] == "applied"
    end

    test "no adapter configured leaves the request unaffected" do
      assert {:ok, _task, http_context, _json} = build_stream()
      refute Map.has_key?(http_context.req_headers, "x-adapter-trace")
    end
  end

  describe "on_finch_request per-request callback" do
    test "callback is applied and its changes appear in the built request" do
      callback = fn req ->
        %{req | headers: req.headers ++ [{"x-per-call", "yes"}]}
      end

      assert {:ok, _task, http_context, _json} = build_stream(on_finch_request: callback)
      assert http_context.req_headers["x-per-call"] == "yes"
    end

    test "callback receives the Finch.Request struct" do
      test_pid = self()

      callback = fn req ->
        send(test_pid, {:received, req})
        req
      end

      assert {:ok, _task, _http_context, _json} = build_stream(on_finch_request: callback)
      assert_receive {:received, %Finch.Request{}}
    end
  end

  describe "precedence: config adapter runs before the per-request callback" do
    test "per-request callback sees the header already added by the config adapter" do
      Application.put_env(:req_llm, :finch_request_adapter, TraceHeaderAdapter)

      test_pid = self()

      callback = fn req ->
        present? = List.keymember?(req.headers, "x-adapter-trace", 0)
        send(test_pid, {:adapter_header_present, present?})
        req
      end

      assert {:ok, _task, _http_context, _json} = build_stream(on_finch_request: callback)
      assert_receive {:adapter_header_present, true}
    end

    test "headers from both the config adapter and the per-request callback are present" do
      Application.put_env(:req_llm, :finch_request_adapter, TraceHeaderAdapter)

      callback = fn req ->
        %{req | headers: req.headers ++ [{"x-per-call", "also"}]}
      end

      assert {:ok, _task, http_context, _json} = build_stream(on_finch_request: callback)
      assert http_context.req_headers["x-adapter-trace"] == "applied"
      assert http_context.req_headers["x-per-call"] == "also"
    end
  end
end
