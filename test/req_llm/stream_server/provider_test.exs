defmodule ReqLLM.StreamServer.ProviderTest.GoogleJsonProvider do
  @moduledoc false
  @behaviour ReqLLM.Provider

  alias ReqLLM.StreamChunk

  def decode_stream_event(%{data: data}, _model) when is_map(data) do
    case data do
      %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} ->
        Enum.flat_map(parts, fn part ->
          case part do
            %{"text" => text} -> [StreamChunk.text(text)]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  def decode_stream_event(_event, _model), do: []

  def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
  def attach(_req, _model, _opts), do: {:error, :not_implemented}
  def encode_body(_req), do: {:error, :not_implemented}
  def decode_response(_resp), do: {:error, :not_implemented}
end

defmodule ReqLLM.StreamServer.ProviderTest.OpenAIJsonProvider do
  @moduledoc false
  @behaviour ReqLLM.Provider

  alias ReqLLM.StreamChunk

  def decode_stream_event(
        %{data: %{"choices" => [%{"delta" => %{"content" => content}}]}},
        _model
      )
      when is_binary(content) do
    [StreamChunk.text(content)]
  end

  def decode_stream_event(_event, _model), do: []

  def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
  def attach(_req, _model, _opts), do: {:error, :not_implemented}
  def encode_body(_req), do: {:error, :not_implemented}
  def decode_response(_resp), do: {:error, :not_implemented}
end

defmodule ReqLLM.StreamServer.ProviderTest.ProviderWithState do
  @moduledoc false
  @behaviour ReqLLM.Provider

  alias ReqLLM.StreamChunk

  def init_stream_state(_model), do: %{count: 0}

  def decode_stream_event(%{data: "content"}, _model, provider_state) do
    new_state = Map.update(provider_state, :count, 1, &(&1 + 1))
    chunk = StreamChunk.text("chunk")
    {[chunk], new_state}
  end

  def decode_stream_event(%{event: "[DONE]"}, _model, _provider_state) do
    {:halt, nil}
  end

  def decode_stream_event(_, _model, provider_state), do: {[], provider_state}

  def flush_stream_state(_model, %{count: count} = provider_state) do
    {[StreamChunk.text("FLUSH:#{count}")], provider_state}
  end

  def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
  def attach(_req, _model, _opts), do: {:error, :not_implemented}
  def encode_body(_req), do: {:error, :not_implemented}
  def decode_response(_resp), do: {:error, :not_implemented}
end

defmodule ReqLLM.StreamServer.ProviderTest do
  @moduledoc """
  StreamServer provider integration tests.

  Covers:
  - Provider integration (SSE decoding delegation)
  - Provider state management
  - JSON mode object assembly

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer.ProviderTest.{
    GoogleJsonProvider,
    OpenAIJsonProvider,
    ProviderWithState
  }

  alias ReqLLM.{StreamChunk, StreamServer}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "provider integration" do
    test "uses provider decode_stream_event when available" do
      server = start_server()
      _task = mock_http_task(server)

      sse_data = ~s(data: {"choices": [{"delta": {"content": "Provider test"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "Provider test"

      StreamServer.cancel(server)
    end

    test "falls back to default decoding when provider doesn't implement decode_stream_event" do
      defmodule MinimalProvider do
        @behaviour ReqLLM.Provider

        def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
        def attach(_req, _model, _opts), do: {:error, :not_implemented}
        def encode_body(_req), do: {:error, :not_implemented}
        def decode_response(_resp), do: {:error, :not_implemented}
      end

      server = start_server(provider_mod: MinimalProvider)
      _task = mock_http_task(server)

      sse_data = ~s(data: {"choices": [{"delta": {"content": "Default decode"}}]}\n\n)
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_data}})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.text == "Default decode"

      StreamServer.cancel(server)
    end
  end

  describe "provider state management" do
    test "threads provider state through decode_stream_event/3" do
      model = %LLMDB.Model{provider: ProviderWithState, id: "test"}
      server = start_server(provider_mod: ProviderWithState, model: model)
      _task = mock_http_task(server)

      StreamServer.http_event(server, {:data, "data: content\n\n"})
      StreamServer.http_event(server, {:data, "data: content\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, chunk1} = StreamServer.next(server, 100)
      assert chunk1 == StreamChunk.text("chunk")

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2 == StreamChunk.text("chunk")

      assert {:ok, flush_chunk} = StreamServer.next(server, 100)
      assert flush_chunk == StreamChunk.text("FLUSH:2")

      assert :halt = StreamServer.next(server, 100)
    end

    test "calls flush_stream_state/2 on finalization" do
      model = %LLMDB.Model{provider: ProviderWithState, id: "test"}
      server = start_server(provider_mod: ProviderWithState, model: model)
      _task = mock_http_task(server)

      StreamServer.http_event(server, {:data, "data: content\n\n"})
      StreamServer.http_event(server, {:data, "data: content\n\n"})
      StreamServer.http_event(server, :done)

      {:ok, _chunk1} = StreamServer.next(server, 100)
      {:ok, _chunk2} = StreamServer.next(server, 100)
      {:ok, flush_chunk} = StreamServer.next(server, 100)

      assert flush_chunk == StreamChunk.text("FLUSH:2")
    end

    test "handles provider without init_stream_state" do
      server = start_server()
      _task = mock_http_task(server)

      sse_data = ~s(data: {"choices": [{"delta": {"content": "hello"}}]}\n\n)
      StreamServer.http_event(server, {:data, sse_data})
      StreamServer.http_event(server, :done)

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk == StreamChunk.text("hello")

      assert :halt = StreamServer.next(server, 100)
    end
  end

  describe "JSON mode object assembly" do
    test "detects JSON mode from Google provider generationConfig" do
      server =
        start_server(
          provider_mod: GoogleJsonProvider,
          model: %LLMDB.Model{provider: :google, id: "gemini-1.5-pro"}
        )

      _task = mock_http_task(server)

      canonical_json = %{
        "generationConfig" => %{
          "responseMimeType" => "application/json"
        }
      }

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, canonical_json)

      sse_chunk1 = ~s|data: {"candidates":[{"content":{"parts":[{"text":"{\\"a\\":"}]}}]}\n\n|
      sse_chunk2 = ~s|data: {"candidates":[{"content":{"parts":[{"text":" 1}"}]}}]}\n\n|

      assert :ok = GenServer.call(server, {:http_event, {:data, sse_chunk1}})
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_chunk2}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, chunk1} = StreamServer.next(server, 1000)
      assert chunk1.type == :content
      assert chunk1.text == ~s|{"a":|

      assert {:ok, chunk2} = StreamServer.next(server, 100)
      assert chunk2.type == :content
      assert chunk2.text == " 1}"

      assert {:ok, tool_chunk} = StreamServer.next(server, 100)
      assert tool_chunk.type == :tool_call
      assert tool_chunk.name == "structured_output"
      assert tool_chunk.arguments == %{"a" => 1}

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "JSON mode with invalid JSON yields no tool_call" do
      server =
        start_server(
          provider_mod: GoogleJsonProvider,
          model: %LLMDB.Model{provider: :google, id: "gemini-1.5-pro"}
        )

      _task = mock_http_task(server)

      canonical_json = %{
        "generationConfig" => %{
          "responseMimeType" => "application/json"
        }
      }

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, canonical_json)

      sse_chunk = ~s|data: {"candidates":[{"content":{"parts":[{"text":"{ invalid"}]}}]}\n\n|
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_chunk}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == "{ invalid"

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "non-JSON mode does not trigger object assembly" do
      server =
        start_server(
          provider_mod: OpenAIJsonProvider,
          model: %LLMDB.Model{provider: :openai, id: "gpt-4"}
        )

      _task = mock_http_task(server)

      canonical_json = %{
        "model" => "gpt-4"
      }

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, canonical_json)

      sse_chunk = ~s|data: {"choices":[{"delta":{"content":"{\\"a\\": 1}"}}]}\n\n|
      assert :ok = GenServer.call(server, {:http_event, {:data, sse_chunk}})
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, chunk} = StreamServer.next(server, 100)
      assert chunk.type == :content
      assert chunk.text == ~s|{"a": 1}|

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end

    test "JSON mode with empty content" do
      server =
        start_server(
          provider_mod: GoogleJsonProvider,
          model: %LLMDB.Model{provider: :google, id: "gemini-1.5-pro"}
        )

      _task = mock_http_task(server)

      canonical_json = %{
        "generationConfig" => %{
          "responseMimeType" => "application/json"
        }
      }

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, canonical_json)

      assert :ok = GenServer.call(server, {:http_event, :done})

      assert :halt = StreamServer.next(server, 100)

      StreamServer.cancel(server)
    end
  end
end
