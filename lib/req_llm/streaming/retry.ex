defmodule ReqLLM.Streaming.Retry do
  @moduledoc """
  Retry wrapper for Finch streaming requests.

  Streaming retries are intentionally conservative: only transient transport
  failures that happen before any response body data is emitted are retried.
  This avoids duplicating partial model output when a stream has already begun.

  Also handles 429 rate limit errors with retry-after header support.
  """

  require Logger

  alias ReqLLM.Streaming.Failure

  @type callback_acc :: term()
  @type callback :: (term(), callback_acc() -> callback_acc())
  @type stream_fun ::
          (Finch.Request.t(), atom(), term(), (term(), term() -> term()), keyword() ->
             {:ok, term()} | {:error, term(), term()})

  @spec stream(
          Finch.Request.t(),
          atom(),
          callback_acc(),
          callback(),
          keyword(),
          stream_fun()
        ) :: {:ok, callback_acc()} | {:error, term(), callback_acc()}
  def stream(request, finch_name, acc, callback, opts, stream_fun \\ &Finch.stream/5) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    stream_opts =
      Keyword.take(opts, [:pool_timeout, :receive_timeout, :request_timeout, :pool_strategy])

    do_stream(
      %{
        request: request,
        finch_name: finch_name,
        acc: acc,
        callback: callback,
        stream_opts: stream_opts,
        stream_fun: stream_fun,
        max_retries: max_retries,
        on_retry: Keyword.get(opts, :on_retry)
      },
      0
    )
  end

  defp do_stream(
         %{
           request: request,
           finch_name: finch_name,
           acc: acc,
           callback: callback,
           stream_opts: stream_opts,
           stream_fun: stream_fun,
           max_retries: max_retries
         } = params,
         attempt
       ) do
    initial_acc = %{
      callback_acc: acc,
      data_received?: false,
      status: nil,
      headers: [],
      error_body: []
    }

    wrapped_callback = fn event, wrapped_acc -> apply_callback(event, wrapped_acc, callback) end

    started_at = System.monotonic_time()

    case stream_fun.(request, finch_name, initial_acc, wrapped_callback, stream_opts) do
      {:ok, %{status: status} = state} when is_integer(status) and status >= 400 ->
        handle_http_failure(params, attempt, :rate_limited, state, started_at)

      {:ok, %{callback_acc: callback_acc}} ->
        {:ok, callback_acc}

      {:error, reason, %{status: status} = state}
      when is_integer(status) and status >= 400 ->
        handle_http_failure(params, attempt, reason, state, started_at)

      {:error, reason, %{data_received?: false, callback_acc: callback_acc} = state}
      when attempt < max_retries ->
        maybe_retry(params, attempt, callback_acc, reason, state, started_at)

      {:error, reason, %{callback_acc: callback_acc}} ->
        {:error, reason, callback_acc}
    end
  end

  defp handle_http_failure(
         %{max_retries: max_retries} = params,
         attempt,
         reason,
         %{status: 429} = state,
         started_at
       )
       when attempt < max_retries do
    maybe_retry(params, attempt, state.callback_acc, reason, state, started_at)
  end

  defp handle_http_failure(%{callback: callback}, _attempt, _reason, state, _started_at) do
    deliver_http_failure(state, callback)
  end

  defp maybe_retry(
         %{max_retries: max_retries} = params,
         attempt,
         callback_acc,
         reason,
         state,
         started_at
       ) do
    case classify_error(reason, state) do
      {:retry, delay_ms} ->
        log_retry(reason, attempt + 1, max_retries, delay_ms, state.status)
        emit_retry(params, attempt, max_retries, delay_ms, state.status, started_at)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        do_stream(params, attempt + 1)

      :no_retry ->
        {:error, reason, callback_acc}
    end
  end

  defp emit_retry(%{on_retry: nil}, _attempt, _max_retries, _delay, _status, _started_at),
    do: :ok

  defp emit_retry(%{on_retry: on_retry}, attempt, max_retries, delay, status, started_at) do
    on_retry.(%{
      attempt: attempt + 1,
      next_attempt: attempt + 2,
      max_retries: max_retries,
      delay: delay,
      duration: System.monotonic_time() - started_at,
      http_status: status
    })
  end

  defp apply_callback({:status, status}, wrapped_acc, _callback)
       when is_integer(status) and status >= 400 do
    %{wrapped_acc | status: status}
  end

  defp apply_callback({:status, status}, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    new_acc = callback.({:status, status}, callback_acc)
    %{wrapped_acc | callback_acc: new_acc, status: status}
  end

  defp apply_callback(
         {:headers, headers},
         %{status: status} = wrapped_acc,
         _callback
       )
       when is_integer(status) and status >= 400 do
    %{wrapped_acc | headers: headers}
  end

  defp apply_callback({:headers, headers}, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    new_acc = callback.({:headers, headers}, callback_acc)
    %{wrapped_acc | callback_acc: new_acc, headers: headers}
  end

  defp apply_callback(
         {:data, chunk},
         %{status: status, error_body: error_body} = wrapped_acc,
         _callback
       )
       when is_integer(status) and status >= 400 do
    %{wrapped_acc | error_body: [chunk | error_body]}
  end

  defp apply_callback({:data, _} = event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc), data_received?: true}
  end

  defp apply_callback(:done, %{status: status} = wrapped_acc, _callback)
       when is_integer(status) and status >= 400 do
    wrapped_acc
  end

  defp apply_callback(event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc)}
  end

  defp classify_error(_reason, %{status: 429} = state) do
    {:retry, extract_retry_after_delay(state.headers)}
  end

  defp classify_error(reason, _state) do
    case Failure.classify(reason) do
      {:transport, :pool_not_available, true} ->
        {:retry, 250}

      {:transport, _reason, true} ->
        {:retry, 0}

      _classification ->
        :no_retry
    end
  end

  defp extract_retry_after_delay(headers) when is_list(headers) do
    retry_after =
      Enum.find_value(headers, fn
        {name, value} when is_binary(name) or is_list(name) ->
          name_str = if is_list(name), do: List.first(name), else: name

          if String.downcase(name_str) == "retry-after" do
            if is_list(value), do: List.first(value), else: value
          else
            nil
          end

        _ ->
          nil
      end)

    case retry_after do
      nil ->
        1000

      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> 1000
        end

      value when is_integer(value) and value > 0 ->
        value * 1000

      _ ->
        1000
    end
  end

  defp extract_retry_after_delay(_), do: 1000

  defp deliver_http_failure(state, callback) do
    callback_acc =
      callback.({:status, state.status}, state.callback_acc)
      |> maybe_emit_headers(callback, state.headers)

    {:error, build_http_error(state), callback_acc}
  end

  defp maybe_emit_headers(callback_acc, _callback, []), do: callback_acc

  defp maybe_emit_headers(callback_acc, callback, headers) do
    callback.({:headers, headers}, callback_acc)
  end

  defp build_http_error(state) do
    response_body =
      state.error_body
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    Failure.api_error(state.status, response_body, state.headers, use_body_as_reason?: true)
  end

  defp log_retry(reason, attempt, max_retries, delay_ms, status) do
    if status == 429 do
      Logger.warning(
        "Retrying streaming request after rate limit (429), waiting #{delay_ms}ms " <>
          "(reason=#{inspect(reason)}, attempt=#{attempt}, max_retries=#{max_retries})"
      )
    else
      Logger.warning(
        "Retrying streaming request after transient transport error " <>
          "(reason=#{inspect(reason)}, attempt=#{attempt}, max_retries=#{max_retries})"
      )
    end
  end
end
