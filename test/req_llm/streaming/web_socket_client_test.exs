defmodule ReqLLM.Streaming.WebSocketClientTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.Streaming.WebSocketClient

  setup do
    fixtures_mode = System.get_env("REQ_LLM_FIXTURES_MODE")
    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")

    on_exit(fn ->
      restore_system_env("REQ_LLM_FIXTURES_MODE", fixtures_mode)
    end)

    :ok
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

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
    def attach_websocket_stream(_model, _context, _opts), do: {:error, :boom}
  end

  defmodule MissingWebSocketProvider do
  end

  defmodule RaisingProvider do
    def attach_websocket_stream(_model, _context, _opts), do: raise("boom")
  end

  defmodule SuccessfulProvider do
    def attach_websocket_stream(_model, _context, _opts) do
      {:ok,
       %{
         url: "ws://127.0.0.1:1/socket",
         headers: [{"authorization", "Bearer secret"}],
         initial_messages: [Jason.encode!(%{"type" => "response.create"})],
         canonical_json: %{"type" => "response.create"}
       }}
    end
  end

  test "returns a request error when provider does not implement websocket streaming" do
    {:ok, stream_server} = EventStreamServer.start_link()
    {:ok, context} = Context.normalize("Hello")

    assert {:error, %ReqLLM.Error.API.Request{}} =
             WebSocketClient.start_stream(
               MissingWebSocketProvider,
               %LLMDB.Model{provider: :test, id: "test"},
               context,
               [],
               stream_server
             )
  end

  test "wraps provider websocket build errors" do
    {:ok, stream_server} = EventStreamServer.start_link()
    {:ok, context} = Context.normalize("Hello")

    assert {:error, {:provider_build_failed, :boom}} =
             WebSocketClient.start_stream(
               ErrorProvider,
               %LLMDB.Model{provider: :test, id: "test"},
               context,
               [],
               stream_server
             )
  end

  test "wraps provider websocket exceptions" do
    {:ok, stream_server} = EventStreamServer.start_link()
    {:ok, context} = Context.normalize("Hello")

    assert {:error, {:build_request_failed, %RuntimeError{message: "boom"}}} =
             WebSocketClient.start_stream(
               RaisingProvider,
               %LLMDB.Model{provider: :test, id: "test"},
               context,
               [],
               stream_server
             )
  end

  test "replays websocket fixtures through the stream server" do
    {:ok, stream_server} = EventStreamServer.start_link()
    {:ok, model} = ReqLLM.model("openrouter:google/gemini-3-flash-preview")
    {:ok, context} = Context.normalize("Hello")

    assert {:ok, task_pid, http_context, canonical_json} =
             WebSocketClient.start_stream(
               ReqLLM.Providers.OpenRouter,
               model,
               context,
               [fixture: "streaming"],
               stream_server
             )

    assert is_pid(task_pid)
    assert %HTTPContext{} = http_context
    assert http_context.url =~ "openrouter.ai"
    assert http_context.status == 200
    assert canonical_json["model"] == "google/gemini-3-flash-preview"

    Process.sleep(50)

    assert Enum.any?(EventStreamServer.events(stream_server), &match?({:status, 200}, &1))
  end

  test "starts websocket streaming tasks with provider-built config" do
    {:ok, stream_server} = EventStreamServer.start_link()
    {:ok, context} = Context.normalize("Hello")

    assert {:ok, task_pid, http_context, canonical_json} =
             WebSocketClient.start_stream(
               SuccessfulProvider,
               %LLMDB.Model{provider: :test, id: "test"},
               context,
               [connect_timeout: 10, receive_timeout: 10],
               stream_server
             )

    assert is_pid(task_pid)
    assert %HTTPContext{} = http_context
    assert http_context.url == "ws://127.0.0.1:1/socket"
    assert canonical_json == %{"type" => "response.create"}
  end
end
