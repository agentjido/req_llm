defmodule ReqLLM.Streaming.InProcessClient do
  @moduledoc false

  alias ReqLLM.Provider.InProcessStream
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer

  require Logger

  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid()) ::
          {:ok, pid(), (-> any()) | nil} | {:error, term()}
  def start_stream(provider_mod, model, context, opts, stream_server_pid) do
    start_stream(
      provider_mod,
      model,
      context,
      opts,
      stream_server_pid,
      ReqLLM.TaskSupervisor
    )
  end

  @doc false
  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid(), term()) ::
          {:ok, pid(), (-> any()) | nil} | {:error, term()}
  def start_stream(provider_mod, model, context, opts, stream_server_pid, task_supervisor) do
    with :ok <- validate_callback(provider_mod),
         {:ok, stream_result} <- provider_mod.attach_in_process_stream(model, context, opts),
         {:ok, stream, cancel} <- normalize_stream(stream_result) do
      start_streaming_task(stream, stream_server_pid, task_supervisor, cancel)
    else
      {:error, reason, cancel} ->
        cancel_stream(cancel)
        log_start_error(reason)

      {:error, reason} ->
        log_start_error(reason)
    end
  rescue
    error ->
      Logger.error("Failed to call provider attach_in_process_stream: #{inspect(error)}")
      {:error, {:build_stream_failed, error}}
  end

  @doc false
  @spec cancel_stream((-> any()) | nil) :: :ok
  def cancel_stream(nil), do: :ok

  def cancel_stream(cancel) when is_function(cancel, 0) do
    {:ok, _pid} = Task.start(fn -> run_cancel_callback(cancel) end)
    :ok
  end

  defp start_streaming_task(stream, stream_server_pid, task_supervisor, cancel) do
    case Task.Supervisor.async(task_supervisor, fn ->
           run_stream(stream, stream_server_pid)
         end) do
      %Task{pid: task_pid} ->
        {:ok, task_pid, cancel}
    end
  rescue
    error ->
      cancel_stream(cancel)
      {:error, {:task_start_failed, error}}
  catch
    kind, reason ->
      cancel_stream(cancel)
      {:error, {:task_start_failed, {kind, reason}}}
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
    with :ok <- validate_cancel(cancel) do
      case validate_enumerable(stream) do
        :ok -> {:ok, stream, cancel}
        {:error, reason} -> {:error, reason, cancel}
      end
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

  defp log_start_error({:task_start_failed, _reason} = reason), do: {:error, reason}

  defp log_start_error(reason) do
    Logger.error("Provider failed to build in-process stream: #{inspect(reason)}")
    {:error, {:provider_build_failed, reason}}
  end

  defp run_cancel_callback(cancel) do
    cancel.()
  rescue
    error -> Logger.warning("In-process stream cancellation failed: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.warning("In-process stream cancellation failed: #{inspect({kind, reason})}")
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
