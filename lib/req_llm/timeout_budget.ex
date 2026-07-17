defmodule ReqLLM.TimeoutBudget do
  @moduledoc false

  alias ReqLLM.Error.API.Timeout

  @capture_key :req_llm_timeout_capture

  @type budget_timeout :: pos_integer() | :infinity
  @type deadline :: :infinity | %{timeout: pos_integer(), expires_at: integer()}

  @spec total_timeout(keyword()) :: budget_timeout()
  def total_timeout(opts) do
    opts
    |> Keyword.get(:total_timeout, Application.get_env(:req_llm, :total_timeout, :infinity))
    |> validate_timeout!(:total_timeout)
  end

  @spec stream_idle_timeout(keyword()) :: {:configured, budget_timeout()} | :legacy
  def stream_idle_timeout(opts) do
    case Keyword.fetch(opts, :stream_idle_timeout) do
      {:ok, timeout} -> {:configured, validate_timeout!(timeout, :stream_idle_timeout)}
      :error -> configured_stream_idle_timeout()
    end
  end

  @spec deadline(keyword()) :: deadline()
  def deadline(opts) do
    case total_timeout(opts) do
      :infinity -> :infinity
      timeout -> %{timeout: timeout, expires_at: now() + timeout}
    end
  end

  @spec remaining(deadline()) :: budget_timeout() | 0
  def remaining(:infinity), do: :infinity

  def remaining(%{expires_at: expires_at}) do
    max(expires_at - now(), 0)
  end

  @spec error(:total | :stream_idle, pos_integer()) :: Timeout.t()
  def error(kind, timeout) do
    Timeout.exception(kind: kind, timeout: timeout)
  end

  @spec request(Req.Request.t(), deadline()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%Req.Request{} = request, :infinity), do: Req.request(request)

  def request(%Req.Request{} = request, %{timeout: timeout} = deadline) do
    capture_ref = make_ref()

    request =
      request
      |> Req.Request.put_private(@capture_key, %{owner: self(), ref: capture_ref})
      |> Req.Request.append_request_steps(
        llm_timeout_capture: &__MODULE__.capture_request_context/1
      )

    case remaining(deadline) do
      0 ->
        timeout_result(request, capture_ref, timeout)

      remaining ->
        request
        |> run_request_task(remaining)
        |> resolve_request_task(request, capture_ref, timeout)
    end
  end

  @doc false
  @spec capture_request_context(Req.Request.t()) :: Req.Request.t()
  def capture_request_context(%Req.Request{} = request) do
    case request.private[@capture_key] do
      %{owner: owner, ref: ref} ->
        send(owner, {__MODULE__, ref, ReqLLM.Telemetry.request_context(request)})

      _other ->
        :ok
    end

    request
  end

  defp configured_stream_idle_timeout do
    case Application.fetch_env(:req_llm, :stream_idle_timeout) do
      {:ok, timeout} -> {:configured, validate_timeout!(timeout, :stream_idle_timeout)}
      :error -> :legacy
    end
  end

  defp validate_timeout!(:infinity, _key), do: :infinity
  defp validate_timeout!(timeout, _key) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(timeout, key) do
    raise ReqLLM.Error.Invalid.Parameter.exception(
            parameter: "#{key} must be a positive integer or :infinity, got: #{inspect(timeout)}"
          )
  end

  defp run_request_task(request, timeout) do
    task = Task.Supervisor.async_nolink(ReqLLM.TaskSupervisor, fn -> Req.request(request) end)
    {task, Task.yield(task, timeout)}
  end

  defp resolve_request_task({_task, {:ok, result}}, _request, capture_ref, _timeout) do
    discard_captured_context(capture_ref)
    result
  end

  defp resolve_request_task({_task, {:exit, reason}}, _request, capture_ref, _timeout) do
    discard_captured_context(capture_ref)
    propagate_task_exit(reason)
  end

  defp resolve_request_task({task, nil}, request, capture_ref, timeout) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        discard_captured_context(capture_ref)
        result

      {:exit, reason} ->
        discard_captured_context(capture_ref)
        propagate_task_exit(reason)

      nil ->
        timeout_result(request, capture_ref, timeout)
    end
  end

  defp timeout_result(request, capture_ref, timeout) do
    error = error(:total, timeout)
    emit_timeout_telemetry(request, capture_ref, error)
    {:error, error}
  end

  defp emit_timeout_telemetry(request, capture_ref, error) do
    context = captured_context(capture_ref) || ReqLLM.Telemetry.request_context(request)

    if context do
      ReqLLM.Telemetry.exception_request(context, error)
    end

    :ok
  end

  defp captured_context(capture_ref, latest \\ nil) do
    receive do
      {__MODULE__, ^capture_ref, context} -> captured_context(capture_ref, context)
    after
      0 -> latest
    end
  end

  defp discard_captured_context(capture_ref) do
    captured_context(capture_ref)
    :ok
  end

  defp propagate_task_exit({%{__exception__: true} = exception, stacktrace})
       when is_list(stacktrace) do
    reraise exception, stacktrace
  end

  defp propagate_task_exit(reason), do: exit(reason)

  defp now, do: System.monotonic_time(:millisecond)
end
