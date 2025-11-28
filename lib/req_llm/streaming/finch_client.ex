defmodule ReqLLM.Streaming.FinchClient do
  @moduledoc """
  Finch HTTP client for ReqLLM streaming operations.

  This module handles the Finch HTTP transport layer for streaming requests,
  forwarding HTTP events to StreamServer for processing. It acts as a bridge
  between Finch's HTTP streaming and the StreamServer's event processing.

  ## Responsibilities

  - Build Finch.Request using provider-specific stream attachment
  - Start supervised Task that calls Finch.stream/5 with callback
  - Forward all HTTP events to StreamServer via GenServer.call
  - Handle connection errors and forward to StreamServer
  - Return HTTPContext for fixture capture

  ## HTTPContext

  The HTTPContext struct provides minimal HTTP metadata needed for fixture
  capture and testing, replacing the more heavyweight Req.Request/Response
  structs used in non-streaming operations.

  ## Provider Integration

  Uses provider-specific `attach_stream/4` callbacks to build streaming
  requests with proper authentication, headers, and request body formatting.
  """

  alias ReqLLM.Streaming.Fixtures
  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.StreamServer

  require Logger
  require ReqLLM.Debug, as: Debug

  @doc """
  Starts a streaming HTTP request and forwards events to StreamServer.

  ## Parameters

    * `provider_mod` - The provider module (e.g., ReqLLM.Providers.OpenAI)
    * `model` - The ReqLLM.Model struct
    * `context` - The ReqLLM.Context with messages to stream
    * `opts` - Additional options for the request
    * `stream_server_pid` - PID of the StreamServer GenServer
    * `finch_name` - Finch process name (defaults to ReqLLM.Finch)

  ## Returns

    * `{:ok, task_pid, http_context, canonical_json}` - Successfully started streaming task
    * `{:error, reason}` - Failed to start streaming

  The returned task will handle the Finch.stream/5 call and forward all HTTP events
  to the StreamServer. The HTTPContext provides minimal metadata for fixture capture.
  """
  @spec start_stream(
          module(),
          LLMDB.Model.t(),
          ReqLLM.Context.t(),
          keyword(),
          pid(),
          atom()
        ) :: {:ok, pid(), HTTPContext.t(), any()} | {:error, term()}
  def start_stream(
        provider_mod,
        model,
        context,
        opts,
        stream_server_pid,
        finch_name \\ ReqLLM.Finch
      ) do
    case maybe_replay_fixture(model, opts) do
      {:fixture, fixture_path} ->
        Debug.dbug(
          fn ->
            test_name = Keyword.get(opts, :fixture, Path.basename(fixture_path, ".json"))
            "step: model=#{LLMDB.Model.spec(model)}, name=#{test_name}"
          end,
          component: :streaming
        )

        start_fixture_replay(fixture_path, stream_server_pid, model)

      :no_fixture ->
        with {:ok, finch_request, http_context, canonical_json} <-
               build_stream_request(provider_mod, model, context, opts, finch_name),
             {:ok, task_pid} <-
               start_streaming_task(
                 finch_request,
                 stream_server_pid,
                 finch_name,
                 http_context,
                 maybe_capture_fixture(model, opts),
                 opts
               ) do
          {:ok, task_pid, http_context, canonical_json}
        end
    end
  end

  # Build Finch.Request using provider callback
  defp build_stream_request(provider_mod, model, context, opts, finch_name) do
    alias ReqLLM.Streaming.Fixtures

    with {:ok, finch_request} <- provider_mod.attach_stream(model, context, opts, finch_name),
         :ok <- validate_http2_body_size(finch_request, finch_name) do
      http_context = Fixtures.HTTPContext.from_finch_request(finch_request)
      canonical_json = Fixtures.canonical_json_from_finch_request(finch_request)

      {:ok, finch_request, http_context, canonical_json}
    else
      {:error, reason} ->
        Logger.error("Provider failed to build streaming request: #{inspect(reason)}")
        {:error, {:provider_build_failed, reason}}
    end
  rescue
    error ->
      Logger.error("Failed to call provider attach_stream: #{inspect(error)}")
      {:error, {:build_request_failed, error}}
  end

  # Start fixture replay task
  defp start_fixture_replay(fixture_path, stream_server_pid, _model) do
    case Code.ensure_loaded(ReqLLM.Test.VCR) do
      {:module, ReqLLM.Test.VCR} ->
        args = [fixture_path, stream_server_pid]
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        {:ok, task_pid} = apply(ReqLLM.Test.VCR, :replay_into_stream_server, args)

        Process.link(task_pid)

        http_context = %HTTPContext{
          url: "fixture://#{fixture_path}",
          method: :post,
          req_headers: %{},
          status: 200,
          resp_headers: %{}
        }

        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        transcript = apply(ReqLLM.Test.VCR, :load!, [fixture_path])
        canonical_json = Map.get(transcript.request, :canonical_json, %{})

        {:ok, task_pid, http_context, canonical_json}

      {:error, _} ->
        {:error, :vcr_not_available}
    end
  end

  # Start supervised task for Finch streaming
  defp start_streaming_task(
         finch_request,
         stream_server_pid,
         finch_name,
         _http_context,
         _fixture_path,
         opts
       ) do
    task_pid =
      Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
        finch_stream_callback = fn
          {:status, status}, acc ->
            StreamServer.http_event(stream_server_pid, {:status, status})
            acc

          {:headers, headers}, acc ->
            StreamServer.http_event(stream_server_pid, {:headers, headers})
            acc

          {:data, chunk}, acc ->
            StreamServer.http_event(stream_server_pid, {:data, chunk})
            acc

          :done, acc ->
            StreamServer.http_event(stream_server_pid, :done)
            acc
        end

        canonical = Fixtures.canonical_json_from_finch_request(finch_request)

        default_timeout =
          if has_thinking_enabled?(canonical) do
            Application.get_env(:req_llm, :thinking_timeout, 300_000)
          else
            Application.get_env(
              :req_llm,
              :stream_receive_timeout,
              Application.get_env(:req_llm, :receive_timeout, 30_000)
            )
          end

        receive_timeout = Keyword.get(opts, :receive_timeout, default_timeout)

        try do
          case Finch.stream(finch_request, finch_name, :ok, finch_stream_callback,
                 receive_timeout: receive_timeout
               ) do
            {:ok, _} ->
              Logger.debug("Finch streaming completed successfully")
              :ok

            {:error, reason, _partial_acc} ->
              Logger.error("Finch streaming failed: #{inspect(reason)}")
              StreamServer.http_event(stream_server_pid, {:error, reason})
              {:error, reason}
          end
        catch
          :exit, reason ->
            Logger.error("Finch streaming task exited: #{inspect(reason)}")
            StreamServer.http_event(stream_server_pid, {:error, {:exit, reason}})
            {:error, {:exit, reason}}

          kind, reason ->
            Logger.error("Finch streaming task crashed: #{kind} #{inspect(reason)}")
            StreamServer.http_event(stream_server_pid, {:error, {kind, reason}})
            {:error, {kind, reason}}
        end
      end)

    {:ok, task_pid.pid}
  rescue
    error ->
      Logger.error("Failed to start streaming task: #{inspect(error)}")
      {:error, {:task_start_failed, error}}
  end

  defp maybe_replay_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.replay_path(model, opts)
      {:error, _} -> :no_fixture
    end
  end

  defp maybe_capture_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.capture_path(model, opts)
      {:error, _} -> nil
    end
  end

  defp has_thinking_enabled?(canonical) do
    case canonical do
      %{"thinking" => %{"type" => "enabled"}} -> true
      %{"generationConfig" => %{"thinkingConfig" => _}} -> true
      _ -> false
    end
  end

  # Validate that HTTP/2 pools won't fail with large request bodies
  # See: https://github.com/sneako/finch/issues/265
  defp validate_http2_body_size(finch_request, finch_name) do
    body_size = byte_size(finch_request.body || "")

    # Only check if body is potentially problematic (>64KB threshold from Finch #265)
    if body_size > 65_535 do
      case get_pool_protocols(finch_name) do
        {:ok, protocols} ->
          if :http2 in protocols do
            {:error, {:http2_body_too_large, body_size, protocols}}
          else
            :ok
          end

        {:error, _} ->
          # Can't determine pool config, assume it's safe
          :ok
      end
    else
      :ok
    end
  end

  # Get the protocols configured for the Finch pool
  defp get_pool_protocols(_finch_name) do
    # Get Finch configuration from application env
    finch_config = Application.get_env(:req_llm, :finch, [])
    pools = Keyword.get(finch_config, :pools, %{})

    # Get default pool config
    case Map.get(pools, :default) do
      nil -> {:error, :no_pool_config}
      pool_config -> {:ok, Keyword.get(pool_config, :protocols, [:http1])}
    end
  rescue
    _ -> {:error, :config_error}
  end
end
