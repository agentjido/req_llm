defmodule ReqLLM.Streaming.WebSocketClient do
  @moduledoc false

  alias ReqLLM.Streaming.Failure
  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.Streaming.WebSocketProtocol
  alias ReqLLM.Streaming.WebSocketSession
  alias ReqLLM.StreamServer

  require Logger
  require ReqLLM.Debug, as: Debug

  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid(), atom()) ::
          {:ok, pid(), HTTPContext.t(), map()} | {:error, term()}
  def start_stream(
        provider_mod,
        model,
        context,
        opts,
        stream_server_pid,
        _finch_name \\ ReqLLM.Finch
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
        with {:ok, config} <- build_stream_request(provider_mod, model, context, opts),
             {:ok, task_pid} <- start_streaming_task(config, stream_server_pid, opts) do
          {:ok, task_pid, config.http_context, config.canonical_json}
        end
    end
  end

  defp build_stream_request(provider_mod, model, context, opts) do
    with true <- function_exported?(provider_mod, :attach_websocket_stream, 3),
         {:ok, config} <- provider_mod.attach_websocket_stream(model, context, opts) do
      http_context =
        Map.get_lazy(config, :http_context, fn ->
          HTTPContext.new(config.url, :get, Map.new(config.headers || []))
        end)

      {:ok,
       %{
         url: config.url,
         headers: config.headers || [],
         initial_messages: config.initial_messages || [],
         http_context: http_context,
         canonical_json: config.canonical_json || %{}
       }}
    else
      false ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason:
             "#{inspect(provider_mod)} does not implement WebSocket streaming for #{LLMDB.Model.spec(model)}"
         )}

      {:error, reason} ->
        Logger.error("Provider failed to build websocket request: #{inspect(reason)}")
        {:error, {:provider_build_failed, reason}}
    end
  rescue
    error ->
      Logger.error("Failed to call provider attach_websocket_stream: #{inspect(error)}")
      {:error, {:build_request_failed, error}}
  end

  defp start_fixture_replay(fixture_path, stream_server_pid, _model) do
    case Code.ensure_loaded(ReqLLM.Test.VCR) do
      {:module, module} ->
        {:ok, task_pid} =
          Function.capture(module, :replay_into_stream_server, 2).(
            fixture_path,
            stream_server_pid
          )

        Process.link(task_pid)

        transcript = Function.capture(module, :load!, 1).(fixture_path)
        canonical_json = Map.get(transcript.request, :canonical_json, %{})
        request_headers = Map.get(transcript.request, :headers, %{})
        response_headers = Function.capture(module, :headers, 1).(transcript)
        status = Function.capture(module, :status, 1).(transcript)

        http_context =
          transcript.request.url
          |> HTTPContext.new(:get, request_headers)
          |> HTTPContext.update_response(status, Map.new(response_headers))

        {:ok, task_pid, http_context, canonical_json}

      {:error, _} ->
        {:error, :vcr_not_available}
    end
  end

  defp start_streaming_task(config, stream_server_pid, opts) do
    opts =
      Keyword.put(opts, :on_retry, fn retry ->
        StreamServer.retry_event(stream_server_pid, retry)
      end)

    task_pid =
      Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
        case reusable_session(opts) do
          nil ->
            start_owned_session(config, stream_server_pid, opts)

          session_pid when is_pid(session_pid) ->
            await_connect_and_stream(session_pid, stream_server_pid, opts,
              initial_messages: config.initial_messages,
              close_on_terminal?: false
            )
        end
      end)

    {:ok, task_pid.pid}
  rescue
    error ->
      Logger.error("Failed to start websocket streaming task: #{inspect(error)}")
      {:error, {:task_start_failed, error}}
  end

  defp start_owned_session(config, stream_server_pid, opts) do
    run_owned_session(config, stream_server_pid, opts, 0)
  end

  defp run_owned_session(config, stream_server_pid, opts, attempt) do
    connect_timeout = connect_timeout(opts)
    started_at = System.monotonic_time()

    result =
      case WebSocketSession.start_link(
             config.url,
             headers: config.headers,
             initial_messages: config.initial_messages,
             connect_timeout: connect_timeout
           ) do
        {:ok, session_pid} ->
          try do
            await_connect_and_stream(session_pid, stream_server_pid, opts,
              close_on_terminal?: true
            )
          after
            close_session(session_pid)
          end

        {:error, reason} ->
          {:error, reason, false}
      end

    handle_owned_session_result(result, config, stream_server_pid, opts, attempt, started_at)
  end

  defp handle_owned_session_result(
         {:error, reason, false},
         config,
         stream_server_pid,
         opts,
         attempt,
         started_at
       ) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    if attempt < max_retries and retryable_transport_error?(reason) do
      emit_retry(opts, attempt, max_retries, started_at)
      run_owned_session(config, stream_server_pid, opts, attempt + 1)
    else
      safe_http_event(stream_server_pid, {:error, reason})
      {:error, reason}
    end
  end

  defp handle_owned_session_result(
         {:error, reason, _data_received?},
         _config,
         server,
         _opts,
         _attempt,
         _started_at
       ) do
    safe_http_event(server, {:error, reason})
    {:error, reason}
  end

  defp handle_owned_session_result(result, _config, _server, _opts, _attempt, _started_at),
    do: result

  defp await_connect_and_stream(session_pid, stream_server_pid, opts, session_opts) do
    case WebSocketSession.await_connected(session_pid, connect_timeout(opts)) do
      :ok ->
        safe_http_event(stream_server_pid, {:status, 101})
        safe_http_event(stream_server_pid, {:headers, [{"upgrade", "websocket"}]})

        case send_initial_messages(session_pid, Keyword.get(session_opts, :initial_messages, [])) do
          :ok ->
            relay_messages(session_pid, stream_server_pid, opts,
              close_on_terminal?: Keyword.get(session_opts, :close_on_terminal?, true)
            )

          {:error, reason} ->
            {:error, reason, false}
        end

      {:error, reason} ->
        {:error, reason, false}
    end
  end

  defp relay_messages(session_pid, stream_server_pid, opts, relay_opts, data_received? \\ false) do
    case WebSocketSession.next_message(session_pid, receive_timeout(opts)) do
      {:ok, message} ->
        case WebSocketProtocol.decode_message(message) do
          {:ok, decoded} ->
            if WebSocketProtocol.error_event?(%{data: decoded}) do
              {:error, {:websocket_error_event, decoded}, true}
            else
              safe_http_event(stream_server_pid, {:data, message})

              if WebSocketProtocol.terminal_event?(%{data: decoded}) do
                maybe_close_session(
                  session_pid,
                  Keyword.get(relay_opts, :close_on_terminal?, true)
                )
              else
                relay_messages(session_pid, stream_server_pid, opts, relay_opts, true)
              end
            end

          {:error, reason} ->
            {:error, {:invalid_websocket_message, reason}, true}
        end

      :halt ->
        {:error, :closed, data_received?}

      {:error, :closed} ->
        {:error, :closed, data_received?}

      {:error, reason} ->
        {:error, reason, data_received?}
    end
  end

  defp reusable_session(opts) do
    opts
    |> Keyword.get(:provider_options, [])
    |> Keyword.get(:openai_websocket_session)
  end

  defp send_initial_messages(session_pid, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case WebSocketSession.send_text(session_pid, message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_close_session(session_pid, true), do: close_session(session_pid)
  defp maybe_close_session(_session_pid, false), do: :ok

  defp close_session(session_pid) do
    if Process.alive?(session_pid), do: WebSocketSession.close(session_pid), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp retryable_transport_error?(reason) do
    match?({:transport, _reason, true}, Failure.classify(reason))
  end

  defp emit_retry(opts, attempt, max_retries, started_at) do
    Logger.warning(
      "Retrying WebSocket stream before provider data " <>
        "(attempt=#{attempt + 1}, max_retries=#{max_retries})"
    )

    if on_retry = Keyword.get(opts, :on_retry) do
      on_retry.(%{
        attempt: attempt + 1,
        next_attempt: attempt + 2,
        max_retries: max_retries,
        delay: 0,
        duration: System.monotonic_time() - started_at,
        http_status: nil
      })
    end

    :ok
  end

  defp connect_timeout(opts) do
    Keyword.get(opts, :connect_timeout, Application.get_env(:req_llm, :connect_timeout, 10_000))
  end

  defp receive_timeout(opts) do
    Keyword.get_lazy(opts, :receive_timeout, fn ->
      Application.get_env(
        :req_llm,
        :stream_receive_timeout,
        Application.get_env(:req_llm, :receive_timeout, 30_000)
      )
    end)
  end

  defp maybe_replay_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.replay_path(model, opts)
      {:error, _} -> :no_fixture
    end
  end

  defp safe_http_event(server, event) do
    StreamServer.http_event(server, event)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, {{:shutdown, _}, _} -> :ok
  end
end
