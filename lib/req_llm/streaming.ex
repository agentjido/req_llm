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
        %LLMDB.Model{provider: :anthropic, name: "claude-3-sonnet"},
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

  alias ReqLLM.{Context, StreamResponse, StreamResponse.MetadataHandle, StreamServer}

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

    * `{:ok, stream_response}` - StreamResponse with stream and metadata_handle
    * `{:error, reason}` - Failed to start streaming components

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:metadata_timeout` - Metadata collection timeout in milliseconds (default: 300_000)
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
  @spec start_stream(module(), LLMDB.Model.t(), Context.t(), keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def start_stream(provider_mod, model, context, opts \\ []) do
    transport = stream_transport(provider_mod, model, opts)

    with {:ok, server_pid} <- start_stream_server(provider_mod, model, transport, opts),
         {:ok, _http_task_pid, http_context, canonical_json} <-
           start_transport_streaming(transport, provider_mod, model, context, opts, server_pid),
         :ok <- set_fixture_context_if_needed(server_pid, http_context, canonical_json) do
      stream_context =
        model
        |> ReqLLM.Telemetry.new_context(
          Keyword.put_new(opts, :context, context),
          mode: :stream,
          transport: telemetry_transport(transport),
          operation: Keyword.get(opts, :operation, :chat),
          reasoning_contract:
            ReqLLM.Telemetry.reasoning_contract_for(
              model,
              Keyword.put_new(opts, :context, context),
              canonical_json
            )
        )
        |> ReqLLM.Telemetry.start_request(canonical_json)

      :ok = StreamServer.set_telemetry_context(server_pid, stream_context)

      # Create lazy stream using Stream.resource
      default_timeout =
        Application.get_env(
          :req_llm,
          :stream_receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      receive_timeout = Keyword.get(opts, :receive_timeout, default_timeout)
      stream = create_lazy_stream(server_pid, receive_timeout)

      # Start metadata collection handle
      metadata_handle = start_metadata_handle(server_pid, opts)

      # Create cancel function
      cancel_fn = fn -> StreamServer.cancel(server_pid) end

      # Build StreamResponse
      stream_response = %StreamResponse{
        stream: stream,
        metadata_handle: metadata_handle,
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
  defp start_stream_server(provider_mod, model, transport, opts) do
    server_opts = [
      provider_mod: provider_mod,
      model: model,
      protocol_parser: protocol_parser_for_transport(transport),
      fixture_path: maybe_capture_fixture(model, opts),
      completion_cleanup_after:
        Keyword.get(
          opts,
          :completion_cleanup_after,
          Application.get_env(:req_llm, :stream_completion_cleanup_after, 30_000)
        ),
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

  defp start_transport_streaming(
         :websocket,
         provider_mod,
         model,
         context,
         opts,
         stream_server_pid
       ) do
    case StreamServer.start_http(
           stream_server_pid,
           provider_mod,
           model,
           context,
           Keyword.put(opts, :stream_transport, :websocket),
           ReqLLM.Finch
         ) do
      {:ok, task_pid, http_context, canonical_json} ->
        {:ok, task_pid, http_context, canonical_json}

      {:error, reason} ->
        Logger.error("Failed to start WebSocket streaming: #{inspect(reason)}")
        {:error, {:websocket_streaming_failed, reason}}
    end
  end

  defp start_transport_streaming(:http, provider_mod, model, context, opts, stream_server_pid) do
    start_http_streaming(provider_mod, model, context, opts, stream_server_pid)
  end

  # Start HTTP streaming through StreamServer
  defp start_http_streaming(provider_mod, model, context, opts, stream_server_pid) do
    finch_name = Keyword.get(opts, :finch_name, ReqLLM.Finch)

    case StreamServer.start_http(
           stream_server_pid,
           provider_mod,
           model,
           context,
           opts,
           finch_name
         ) do
      {:ok, task_pid, http_context, canonical_json} ->
        {:ok, task_pid, http_context, canonical_json}

      {:error, {:provider_build_failed, {:http2_body_too_large, body_size, protocols}}} ->
        message = format_http2_error_message(body_size, protocols)
        Logger.error(message)
        {:error, {:http2_body_too_large, message}}

      {:error, reason} ->
        Logger.error("Failed to start HTTP streaming: #{inspect(reason)}")
        {:error, {:http_streaming_failed, reason}}
    end
  end

  defp stream_transport(provider_mod, model, opts) do
    if function_exported?(provider_mod, :stream_transport, 2) do
      provider_mod.stream_transport(model, opts)
    else
      :http
    end
  end

  defp telemetry_transport(:websocket), do: :websocket
  defp telemetry_transport(_transport), do: :finch

  defp protocol_parser_for_transport(:websocket),
    do: &ReqLLM.Streaming.WebSocketProtocol.parse_message/2

  defp protocol_parser_for_transport(_transport), do: nil

  defp format_http2_error_message(body_size, protocols) do
    size_kb = div(body_size, 1024)

    """
    Request body (#{size_kb}KB) exceeds safe limit for HTTP/2 connections (64KB).

    This is due to a known issue in Finch's HTTP/2 implementation:
    https://github.com/sneako/finch/issues/265

    Your current pool configuration uses: #{inspect(protocols)}

    To fix this, configure ReqLLM to use HTTP/1-only pools (recommended):

        config :req_llm,
          finch: [
            name: ReqLLM.Finch,
            pools: %{
              :default => [protocols: [:http1], size: 1, count: 8]
            }
          ]

    See the ReqLLM README section "HTTP/2 Configuration (Advanced)" for more details:
    https://github.com/agentjido/req_llm#http2-configuration-advanced
    """
  end

  defp maybe_capture_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.capture_path(model, opts)
      {:error, _} -> nil
    end
  end

  defp set_fixture_context_if_needed(server_pid, http_context, canonical_json) do
    if fixture_mode() == :record do
      ReqLLM.StreamServer.set_fixture_context(server_pid, http_context, canonical_json)
    else
      :ok
    end
  end

  defp fixture_mode do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.mode()
      {:error, _} -> :replay
    end
  end

  # Create lazy stream using Stream.resource that calls StreamServer.next/2
  defp create_lazy_stream(server_pid, timeout) do
    Stream.resource(
      fn -> %{server: server_pid, exhausted?: false} end,
      fn %{server: server} = state ->
        case StreamServer.next(server, timeout) do
          {:ok, chunk} ->
            {[chunk], state}

          :halt ->
            {:halt, %{state | exhausted?: true}}

          {:error, reason} ->
            raise %ReqLLM.Error.API.Stream{
              reason: "Stream failed: #{inspect(reason)}",
              cause: reason
            }
        end
      end,
      fn %{server: server, exhausted?: exhausted?} ->
        if not exhausted? do
          safe_cancel_stream_server(server)
        end
      end
    )
  end

  defp safe_cancel_stream_server(server) do
    if Process.alive?(server) do
      StreamServer.cancel(server)
    else
      :ok
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, {{:shutdown, _}, _} -> :ok
  end

  defp start_metadata_handle(server_pid, opts) do
    default_metadata_timeout = Application.get_env(:req_llm, :metadata_timeout, 300_000)
    metadata_timeout = Keyword.get(opts, :metadata_timeout, default_metadata_timeout)

    fetch_fun = fn ->
      case StreamServer.await_metadata(server_pid, metadata_timeout) do
        {:ok, metadata} ->
          metadata

        {:error, reason} ->
          Logger.warning("Metadata collection failed: #{inspect(reason)}")
          %{error: reason}
      end
    end

    case MetadataHandle.start_link(fetch_fun) do
      {:ok, handle} -> handle
      {:error, reason} -> raise "Failed to start metadata handle: #{inspect(reason)}"
    end
  end
end
