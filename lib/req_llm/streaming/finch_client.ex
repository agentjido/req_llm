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

  alias ReqLLM.Streaming.{Failure, Fixtures, Retry}
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
         finch_request <- transform_request(finch_request, opts),
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
    stream_opts =
      finch_request
      |> Fixtures.canonical_json_from_finch_request()
      |> stream_options(opts)
      |> Keyword.put(:on_retry, fn retry -> StreamServer.retry_event(stream_server_pid, retry) end)

    task_pid =
      Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
        finch_stream_callback = fn
          {:status, status}, acc ->
            safe_http_event(stream_server_pid, {:status, status})
            acc

          {:headers, headers}, acc ->
            safe_http_event(stream_server_pid, {:headers, headers})
            acc

          {:data, chunk}, acc ->
            safe_http_event(stream_server_pid, {:data, chunk})
            acc

          :done, acc ->
            safe_http_event(stream_server_pid, :done)
            acc
        end

        try do
          case Retry.stream(
                 finch_request,
                 finch_name,
                 :ok,
                 finch_stream_callback,
                 stream_opts
               ) do
            {:ok, _} ->
              :ok

            {:error, reason, _callback_acc} ->
              forward_stream_failure(stream_server_pid, reason)
          end
        catch
          :exit, reason ->
            forward_stream_failure(stream_server_pid, {:exit, reason})

          kind, reason ->
            forward_stream_failure(stream_server_pid, {kind, reason})
        end
      end)

    {:ok, task_pid.pid}
  rescue
    error ->
      Logger.error("Failed to start streaming task: #{inspect(error)}")
      {:error, {:task_start_failed, error}}
  end

  defp forward_stream_failure(stream_server_pid, reason) do
    case Failure.log(reason) do
      :cancelled ->
        safe_http_event(stream_server_pid, {:cancelled, reason})

      _classification ->
        safe_http_event(stream_server_pid, {:error, reason})
    end

    {:error, reason}
  end

  @doc false
  @spec stream_options(map(), keyword()) :: keyword()
  def stream_options(canonical, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, default_receive_timeout(canonical))
    pool_timeout = Keyword.get(opts, :pool_timeout, default_pool_timeout(receive_timeout))

    [
      pool_timeout: validate_timeout!(pool_timeout, :pool_timeout),
      receive_timeout: receive_timeout,
      max_retries: Keyword.get(opts, :max_retries, 3)
    ]
    |> maybe_put_option(:request_timeout, Keyword.get(opts, :request_timeout))
    |> maybe_put_option(:pool_strategy, pool_strategy(opts))
  end

  # Apply config-level adapter then per-request callback, in that order.
  defp transform_request(finch_request, opts) do
    finch_request
    |> apply_config_adapter()
    |> apply_per_request_callback(opts)
  end

  defp apply_config_adapter(finch_request) do
    case Application.get_env(:req_llm, :finch_request_adapter) do
      nil -> finch_request
      adapter -> adapter.call(finch_request)
    end
  end

  defp apply_per_request_callback(finch_request, opts) do
    case Keyword.get(opts, :on_finch_request) do
      nil -> finch_request
      fun -> fun.(finch_request)
    end
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

  defp default_receive_timeout(canonical) do
    if has_thinking_enabled?(canonical) do
      Application.get_env(:req_llm, :thinking_timeout, 300_000)
    else
      Application.get_env(
        :req_llm,
        :stream_receive_timeout,
        Application.get_env(:req_llm, :receive_timeout, 30_000)
      )
    end
  end

  defp default_pool_timeout(receive_timeout) do
    case Application.get_env(:req_llm, :stream_pool_timeout) do
      nil -> receive_timeout
      timeout -> timeout
    end
  end

  defp validate_timeout!(:infinity, _key), do: :infinity

  defp validate_timeout!(timeout, _key) when is_integer(timeout) and timeout >= 0, do: timeout

  defp validate_timeout!(timeout, key) do
    raise ReqLLM.Error.Invalid.Parameter.exception(
            parameter:
              "#{key} must be a non-negative integer or :infinity, got: #{inspect(timeout)}"
          )
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_http_event(server, event) do
    StreamServer.http_event(server, event)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, {{:shutdown, _}, _} -> :ok
  end

  # Validate that HTTP/2 pools won't fail with large request bodies
  # See: https://github.com/sneako/finch/issues/265
  defp validate_http2_body_size(finch_request, finch_name) do
    body_size = request_body_size(finch_request.body)

    # Only check if body is potentially problematic (>64KB threshold from Finch #265)
    if body_size > 65_535 do
      case get_pool_protocols(finch_request, finch_name) do
        {:ok, protocols} ->
          if mixed_http2_protocols?(protocols) do
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

  defp mixed_http2_protocols?(protocols) do
    :http1 in protocols and :http2 in protocols
  end

  defp get_pool_protocols(finch_request, finch_name) do
    finch_config = ReqLLM.Application.get_finch_config()
    configured_name = Keyword.get(finch_config, :name, ReqLLM.Finch)
    pools = Keyword.get(finch_config, :pools, %{})

    cond do
      configured_name != finch_name ->
        {:error, :unknown_finch_config}

      is_map(pools) ->
        case matching_pool_config(pools, finch_request) do
          nil -> {:error, :no_pool_config}
          pool_config -> {:ok, pool_protocols(pool_config)}
        end

      true ->
        {:error, :no_pool_config}
    end
  rescue
    _ -> {:error, :config_error}
  end

  defp matching_pool_config(pools, finch_request) do
    request_pool = request_pool(finch_request)

    Enum.find_value(pools, fn
      {:default, _pool_config} ->
        nil

      {destination, pool_config} ->
        if pool_matches?(destination, request_pool), do: pool_config
    end) || Map.get(pools, :default)
  end

  defp request_pool(%Finch.Request{scheme: scheme, unix_socket: unix_socket, pool_tag: tag})
       when is_binary(unix_socket) do
    Finch.Pool.from_name({scheme, {:local, unix_socket}, 0, tag})
  end

  defp request_pool(%Finch.Request{scheme: scheme, host: host, port: port, pool_tag: tag}) do
    Finch.Pool.from_name({scheme, host, port, tag})
  end

  defp pool_matches?(%Finch.Pool{} = destination, request_pool), do: destination == request_pool

  defp pool_matches?(destination, request_pool) when is_binary(destination) do
    Finch.Pool.new(destination) == request_pool
  rescue
    _ -> false
  end

  defp pool_matches?({scheme, {:local, path}}, request_pool)
       when is_atom(scheme) and is_binary(path) do
    Finch.Pool.new({scheme, {:local, path}}) == request_pool
  end

  defp pool_matches?(_destination, _request_pool), do: false

  defp pool_protocols(pool_config) when is_list(pool_config) do
    Keyword.get(pool_config, :protocols, [:http1])
  end

  defp pool_protocols(pool_config) when is_map(pool_config) do
    Map.get(pool_config, :protocols, [:http1])
  end

  defp pool_protocols(_pool_config), do: [:http1]

  defp pool_strategy(opts) do
    Keyword.get(opts, :pool_strategy, Application.get_env(:req_llm, :stream_pool_strategy))
  end

  defp request_body_size(nil), do: 0
  defp request_body_size({:stream, _}), do: 0
  defp request_body_size(body), do: IO.iodata_length(body)
end
