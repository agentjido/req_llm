defmodule ReqLLM.Streaming.InProcessClient do
  @moduledoc false

  alias ReqLLM.Provider.InProcessStream
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  require Logger

  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid()) ::
          {:ok, pid(), (-> any()) | nil} | {:error, term()}
  def start_stream(provider_mod, model, context, opts, stream_server_pid) do
    with :ok <- validate_callback(provider_mod),
         {:ok, stream_result} <- provider_mod.attach_in_process_stream(model, context, opts),
         {:ok, stream, cancel} <- normalize_stream(stream_result),
         {:ok, task_pid} <- start_streaming_task(stream, stream_server_pid) do
      {:ok, task_pid, cancel}
    else
      {:error, {:task_start_failed, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("Provider failed to build in-process stream: #{inspect(reason)}")
        {:error, {:provider_build_failed, reason}}
    end
  rescue
    error ->
      Logger.error("Failed to call provider attach_in_process_stream: #{inspect(error)}")
      {:error, {:build_stream_failed, error}}
  end

  @doc false
  @spec run_stream(Enumerable.t(), pid()) :: :ok | {:error, term()}
  def run_stream(stream, stream_server_pid) do
    result =
      Enum.reduce_while(stream, :open, fn
        %StreamChunk{} = chunk, _state ->
          :ok = safe_stream_event(stream_server_pid, {:chunk, chunk})

          if terminal_chunk?(chunk) do
            {:halt, :terminal}
          else
            {:cont, :open}
          end

        {:error, reason}, _state ->
          :ok = safe_stream_event(stream_server_pid, {:error, reason})
          {:halt, {:error, reason}}

        value, _state ->
          reason = {:invalid_in_process_stream_item, value}
          :ok = safe_stream_event(stream_server_pid, {:error, reason})
          {:halt, {:error, reason}}
      end)

    case result do
      :open ->
        :ok = safe_stream_event(stream_server_pid, :done)
        :ok

      :terminal ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      :ok = safe_stream_event(stream_server_pid, {:error, error})
      {:error, error}
  catch
    kind, reason ->
      failure = {kind, reason}
      :ok = safe_stream_event(stream_server_pid, {:error, failure})
      {:error, failure}
  end

  defp validate_callback(provider_mod) do
    if function_exported?(provider_mod, :attach_in_process_stream, 3) do
      :ok
    else
      {:error, {:missing_callback, :attach_in_process_stream, 3}}
    end
  end

  defp normalize_stream(%InProcessStream{stream: stream, cancel: cancel}) do
    with :ok <- validate_enumerable(stream),
         :ok <- validate_cancel(cancel) do
      {:ok, stream, cancel}
    end
  end

  defp normalize_stream(stream) do
    case validate_enumerable(stream) do
      :ok -> {:ok, stream, nil}
      {:error, _reason} = error -> error
    end
  end

  defp validate_enumerable(stream) do
    if Enumerable.impl_for(stream) do
      :ok
    else
      {:error, {:invalid_in_process_stream, stream}}
    end
  end

  defp validate_cancel(nil), do: :ok
  defp validate_cancel(cancel) when is_function(cancel, 0), do: :ok
  defp validate_cancel(cancel), do: {:error, {:invalid_cancel_callback, cancel}}

  defp start_streaming_task(stream, stream_server_pid) do
    task =
      Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
        run_stream(stream, stream_server_pid)
      end)

    {:ok, task.pid}
  rescue
    error -> {:error, {:task_start_failed, error}}
  end

  defp safe_stream_event(stream_server_pid, event) do
    StreamServer.in_process_event(stream_server_pid, event)
  catch
    :exit, _reason -> :ok
  end

  defp terminal_chunk?(%StreamChunk{type: :meta, metadata: metadata})
       when is_map(metadata) do
    Map.get(metadata, :terminal?) == true or Map.get(metadata, "terminal?") == true
  end

  defp terminal_chunk?(_chunk), do: false
end
