defmodule ReqLLM.Streaming.WebSocketClient do
  @moduledoc false

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
    case WebSocketSession.start_link(
           config.url,
           headers: config.headers,
           initial_messages: config.initial_messages
         ) do
      {:ok, session_pid} ->
        await_connect_and_stream(session_pid, stream_server_pid, opts, close_on_terminal?: true)

      {:error, reason} ->
        safe_http_event(stream_server_pid, {:error, reason})
        {:error, reason}
    end
  end

  defp await_connect_and_stream(session_pid, stream_server_pid, opts, session_opts) do
    connect_timeout =
      Keyword.get(opts, :connect_timeout, Keyword.get(opts, :receive_timeout, 30_000))

    case WebSocketSession.await_connected(session_pid, connect_timeout) do
      :ok ->
        safe_http_event(stream_server_pid, {:status, 101})
        safe_http_event(stream_server_pid, {:headers, [{"upgrade", "websocket"}]})

        case send_initial_messages(session_pid, Keyword.get(session_opts, :initial_messages, [])) do
          :ok ->
            relay_messages(session_pid, stream_server_pid, opts,
              close_on_terminal?: Keyword.get(session_opts, :close_on_terminal?, true)
            )

          {:error, reason} ->
            safe_http_event(stream_server_pid, {:error, reason})
            {:error, reason}
        end

      {:error, reason} ->
        safe_http_event(stream_server_pid, {:error, reason})
        {:error, reason}
    end
  end

  defp relay_messages(session_pid, stream_server_pid, opts, relay_opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 30_000)

    case WebSocketSession.next_message(session_pid, receive_timeout) do
      {:ok, message} ->
        case WebSocketProtocol.decode_message(message) do
          {:ok, decoded} ->
            if WebSocketProtocol.error_event?(%{data: decoded}) do
              safe_http_event(stream_server_pid, {:error, {:websocket_error_event, decoded}})
              {:error, decoded}
            else
              safe_http_event(stream_server_pid, {:data, message})

              if WebSocketProtocol.terminal_event?(%{data: decoded}) do
                maybe_close_session(
                  session_pid,
                  Keyword.get(relay_opts, :close_on_terminal?, true)
                )
              else
                relay_messages(session_pid, stream_server_pid, opts, relay_opts)
              end
            end

          {:error, reason} ->
            safe_http_event(stream_server_pid, {:error, {:invalid_websocket_message, reason}})
            {:error, reason}
        end

      :halt ->
        :ok

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        safe_http_event(stream_server_pid, {:error, reason})
        {:error, reason}
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

  defp maybe_close_session(session_pid, true), do: WebSocketSession.close(session_pid)
  defp maybe_close_session(_session_pid, false), do: :ok

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
