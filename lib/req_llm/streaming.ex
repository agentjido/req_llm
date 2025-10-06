defmodule ReqLLM.Streaming do
  @moduledoc """
  Main orchestration for ReqLLM streaming operations.

  This module coordinates StreamServer, FinchClient, and StreamResponse to provide
  a cohesive streaming system. It serves as the entry point for all streaming
  operations and handles the complex coordination between components.

  ## Architecture

  The streaming system consists of three main components:

  - `StreamServer` - GenServer managing stream state and event processing
  - `FinchClient` - HTTP transport layer using Finch for streaming requests  
  - `StreamResponse` - User-facing API providing streams and metadata tasks

  ## Flow

  1. `start_stream/4` creates StreamServer with provider configuration
  2. FinchClient builds provider-specific HTTP request and starts streaming
  3. HTTP task is attached to StreamServer for monitoring and cleanup
  4. StreamResponse provides lazy stream using `Stream.resource/3`
  5. Metadata task runs concurrently to collect usage and finish_reason
  6. Cancel function provides cleanup of all components

  ## Example

      {:ok, stream_response} = ReqLLM.Streaming.start_stream(
        ReqLLM.Providers.Anthropic,
        %ReqLLM.Model{provider: :anthropic, name: "claude-3-sonnet"}, 
        ReqLLM.Context.new("Hello!"),
        []
      )

      # Stream tokens
      stream_response.stream
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

      # Get metadata
      usage = ReqLLM.StreamResponse.usage(stream_response)

  """

  alias ReqLLM.Streaming.FinchClient
  alias ReqLLM.StreamServer
  alias ReqLLM.{Context, Model, StreamResponse}

  require Logger

  @doc """
  Start a streaming session with coordinated StreamServer, FinchClient, and StreamResponse.

  This is the main entry point for streaming operations. It orchestrates all components
  to provide a cohesive streaming experience with concurrent metadata collection.

  ## Parameters

    * `provider_mod` - Provider module (e.g., `ReqLLM.Providers.Anthropic`)
    * `model` - Model configuration struct
    * `context` - Conversation context with messages
    * `opts` - Additional options (timeout, fixture_path, etc.)

  ## Returns

    * `{:ok, stream_response}` - StreamResponse with stream and metadata_task
    * `{:error, reason}` - Failed to start streaming components

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:fixture_path` - Path for test fixture capture (testing only)
    * `:finch_name` - Finch pool name (default: ReqLLM.Finch)

  ## Examples

      # Basic streaming
      {:ok, stream_response} = ReqLLM.Streaming.start_stream(
        ReqLLM.Providers.Anthropic,
        model,
        context,
        []
      )

      # With options
      {:ok, stream_response} = ReqLLM.Streaming.start_stream(
        provider_mod,
        model, 
        context,
        timeout: 60_000,
        fixture_path: "/tmp/test_fixture.json"
      )

  ## Error Cases

  The function can fail at several points:

  - StreamServer fails to start
  - Provider's build_stream_request/4 fails  
  - HTTP streaming task fails to start
  - Task attachment fails

  All failures return `{:error, reason}` with descriptive error information.
  """
  @spec start_stream(module(), Model.t(), Context.t(), keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def start_stream(provider_mod, model, context, opts \\ []) do
    with {:ok, server_pid} <- start_stream_server(provider_mod, model, opts),
         {:ok, http_task_pid, http_context, canonical_json} <-
           start_http_streaming(provider_mod, model, context, opts, server_pid),
         :ok <- StreamServer.attach_http_task(server_pid, http_task_pid),
         :ok <- set_fixture_context_if_needed(server_pid, http_context, canonical_json) do
      # Create lazy stream using Stream.resource
      default_timeout =
        Application.get_env(
          :req_llm,
          :stream_receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      receive_timeout = Keyword.get(opts, :receive_timeout, default_timeout)
      stream = create_lazy_stream(server_pid, receive_timeout)

      # Start metadata collection task
      metadata_task = start_metadata_task(server_pid)

      # Create cancel function
      cancel_fn = fn -> StreamServer.cancel(server_pid) end

      # Build StreamResponse
      stream_response = %StreamResponse{
        stream: stream,
        metadata_task: metadata_task,
        cancel: cancel_fn,
        model: model,
        context: context
      }

      {:ok, stream_response}
    else
      {:error, reason} ->
        Logger.error("Failed to start streaming: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Start StreamServer with provider configuration
  defp start_stream_server(provider_mod, model, opts) do
    server_opts = [
      provider_mod: provider_mod,
      model: model,
      fixture_path: maybe_capture_fixture(model, opts),
      high_watermark: Keyword.get(opts, :high_watermark, 500)
    ]

    genserver_opts = Keyword.take(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])
    all_opts = Keyword.merge(server_opts, genserver_opts)

    case StreamServer.start_link(all_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start StreamServer: #{inspect(reason)}")
        {:error, {:stream_server_failed, reason}}
    end
  end

  # Start HTTP streaming using FinchClient
  defp start_http_streaming(provider_mod, model, context, opts, stream_server_pid) do
    finch_name = Keyword.get(opts, :finch_name, ReqLLM.Finch)

    case FinchClient.start_stream(
           provider_mod,
           model,
           context,
           opts,
           stream_server_pid,
           finch_name
         ) do
      {:ok, task_pid, http_context, canonical_json} ->
        {:ok, task_pid, http_context, canonical_json}

      {:error, reason} ->
        Logger.error("Failed to start HTTP streaming: #{inspect(reason)}")
        {:error, {:http_streaming_failed, reason}}
    end
  end

  # Set fixture context if fixture capture is enabled
  defp set_fixture_context_if_needed(server_pid, http_context, canonical_json) do
    if fixture_mode() == :record do
      StreamServer.set_fixture_context(server_pid, http_context, canonical_json)
    else
      :ok
    end
  end

  defp fixture_mode do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> apply(mod, :mode, [])
      {:error, _} -> :replay
    end
  end

  defp maybe_capture_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> apply(mod, :capture_path, [model, opts])
      {:error, _} -> nil
    end
  end

  # Create lazy stream using Stream.resource that calls StreamServer.next/2
  defp create_lazy_stream(server_pid, timeout) do
    Stream.resource(
      # start_fn: return the server pid
      fn -> server_pid end,
      # next_fn: get next chunk from server
      fn server ->
        case StreamServer.next(server, timeout) do
          {:ok, chunk} ->
            {[chunk], server}

          :halt ->
            {:halt, server}

          {:error, reason} ->
            Logger.error("Stream error: #{inspect(reason)}")
            {:halt, server}
        end
      end,
      # after_fn: no-op, cleanup handled by cancel function
      fn _server -> :ok end
    )
  end

  # Start metadata collection task that awaits completion
  defp start_metadata_task(server_pid) do
    Task.async(fn ->
      metadata_timeout = Application.get_env(:req_llm, :metadata_timeout, 60_000)

      case StreamServer.await_metadata(server_pid, metadata_timeout) do
        {:ok, metadata} ->
          metadata

        {:error, reason} ->
          Logger.warning("Metadata collection failed: #{inspect(reason)}")
          %{}
      end
    end)
  end
end
