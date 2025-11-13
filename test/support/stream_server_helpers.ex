defmodule ReqLLM.Test.StreamServerHelpers do
  @moduledoc """
  Shared test helpers for StreamServer testing.

  Provides:
  - MockProvider: A test provider implementing decode_stream_event for common SSE patterns
  - Helper functions for starting servers and mocking HTTP tasks
  - Utilities for testing StreamServer behavior in isolation
  """

  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  defmodule MockProvider do
    @moduledoc """
    Mock provider for testing StreamServer SSE parsing and token queuing.

    Implements decode_stream_event to handle common SSE patterns:
    - OpenAI-style: `{"choices": [{"delta": {"content": "..."}}]}`
    - Anthropic-style: `{"type": "content_block_delta", "delta": {"text": "..."}}`
    - Usage metadata: `{"usage": {...}}`
    """
    @behaviour ReqLLM.Provider

    def decode_stream_event(
          %{data: %{"choices" => [%{"delta" => %{"content" => content}}]}},
          _model
        )
        when is_binary(content) do
      [StreamChunk.text(content)]
    end

    def decode_stream_event(
          %{data: %{"type" => "content_block_delta", "delta" => %{"text" => text}}},
          _model
        ) do
      [StreamChunk.text(text)]
    end

    def decode_stream_event(%{data: %{"usage" => usage}}, _model) do
      [StreamChunk.meta(%{usage: usage})]
    end

    def decode_stream_event(_event, _model), do: []

    def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
    def attach(_req, _model, _opts), do: {:error, :not_implemented}
    def encode_body(_req), do: {:error, :not_implemented}
    def decode_response(_resp), do: {:error, :not_implemented}
  end

  @doc """
  Starts a StreamServer with test-friendly defaults.

  ## Options
  - `:provider_mod` - Provider module (default: MockProvider)
  - `:model` - Model struct (default: test model)
  - `:high_watermark` - Queue size limit for backpressure testing
  - Other StreamServer options

  ## Examples

      server = start_server()
      server = start_server(high_watermark: 2)
      server = start_server(provider_mod: CustomProvider)
  """
  def start_server(opts \\ []) do
    default_opts = [
      provider_mod: MockProvider,
      model: %LLMDB.Model{provider: :test, id: "test-model"}
    ]

    opts = Keyword.merge(default_opts, opts)
    {:ok, server} = StreamServer.start_link(opts)
    server
  end

  @doc """
  Creates a mock HTTP task and attaches it to the StreamServer.

  Returns the task for manual control in tests (e.g., killing to test error handling).

  ## Examples

      server = start_server()
      task = mock_http_task(server)
      Process.exit(task.pid, :kill)  # Simulate HTTP failure
  """
  def mock_http_task(server) do
    task = Task.async(fn -> :timer.sleep(50_000) end)
    StreamServer.attach_http_task(server, task.pid)
    task
  end
end
