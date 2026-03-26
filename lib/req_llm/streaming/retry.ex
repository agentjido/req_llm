defmodule ReqLLM.Streaming.Retry do
  @moduledoc """
  Retry wrapper for Finch streaming requests.

  Streaming retries are intentionally conservative: only transient transport
  failures that happen before any response body data is emitted are retried.
  This avoids duplicating partial model output when a stream has already begun.

  Also handles 429 rate limit errors with retry-after header support.
  """

  require Logger

  @retryable_reasons [:closed, :timeout, :econnrefused]

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
    stream_opts = Keyword.take(opts, [:receive_timeout])

    do_stream(
      %{
        request: request,
        finch_name: finch_name,
        acc: acc,
        callback: callback,
        stream_opts: stream_opts,
        stream_fun: stream_fun,
        max_retries: max_retries
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

    case stream_fun.(request, finch_name, initial_acc, wrapped_callback, stream_opts) do
      {:ok, %{status: 429} = state} when attempt < max_retries ->
        maybe_retry(params, attempt, state.callback_acc, :rate_limited, state)

      {:ok, %{status: 429} = state} ->
        deliver_rate_limit_failure(state, callback)

      {:ok, %{callback_acc: callback_acc}} ->
        {:ok, callback_acc}

      {:error, reason, %{status: 429} = state} when attempt < max_retries ->
        maybe_retry(params, attempt, state.callback_acc, reason, state)

      {:error, _reason, %{status: 429} = state} ->
        deliver_rate_limit_failure(state, callback)

      {:error, reason, %{data_received?: false, callback_acc: callback_acc} = state}
      when attempt < max_retries ->
        maybe_retry(params, attempt, callback_acc, reason, state)

      {:error, reason, %{callback_acc: callback_acc}} ->
        {:error, reason, callback_acc}
    end
  end

  defp maybe_retry(%{max_retries: max_retries} = params, attempt, callback_acc, reason, state) do
    case classify_error(reason, state) do
      {:retry, delay_ms} ->
        log_retry(reason, attempt + 1, max_retries, delay_ms)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        do_stream(params, attempt + 1)

      :no_retry ->
        {:error, reason, callback_acc}
    end
  end

  defp apply_callback({:status, 429}, wrapped_acc, _callback) do
    %{wrapped_acc | status: 429}
  end

  defp apply_callback({:status, status}, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    new_acc = callback.({:status, status}, callback_acc)
    %{wrapped_acc | callback_acc: new_acc, status: status}
  end

  defp apply_callback({:headers, headers}, %{status: 429} = wrapped_acc, _callback) do
    %{wrapped_acc | headers: headers}
  end

  defp apply_callback({:headers, headers}, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    new_acc = callback.({:headers, headers}, callback_acc)
    %{wrapped_acc | callback_acc: new_acc, headers: headers}
  end

  defp apply_callback(
         {:data, chunk},
         %{status: 429, error_body: error_body} = wrapped_acc,
         _callback
       ) do
    %{wrapped_acc | error_body: [chunk | error_body]}
  end

  defp apply_callback({:data, _} = event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc), data_received?: true}
  end

  defp apply_callback(:done, %{status: 429} = wrapped_acc, _callback) do
    wrapped_acc
  end

  defp apply_callback(event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc)}
  end

  defp classify_error(%Mint.TransportError{reason: reason}, _state)
       when reason in @retryable_reasons,
       do: {:retry, 0}

  defp classify_error(%Req.TransportError{reason: reason}, _state)
       when reason in @retryable_reasons,
       do: {:retry, 0}

  defp classify_error(_reason, %{status: 429} = state) do
    {:retry, extract_retry_after_delay(state.headers)}
  end

  defp classify_error(_reason, _state) do
    :no_retry
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

  defp deliver_rate_limit_failure(state, callback) do
    callback_acc =
      callback.({:status, 429}, state.callback_acc)
      |> maybe_emit_headers(callback, state.headers)

    {:error, build_rate_limit_error(state), callback_acc}
  end

  defp maybe_emit_headers(callback_acc, _callback, []), do: callback_acc

  defp maybe_emit_headers(callback_acc, callback, headers) do
    callback.({:headers, headers}, callback_acc)
  end

  defp build_rate_limit_error(state) do
    response_body =
      state.error_body
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> decode_rate_limit_body()

    reason =
      case response_body do
        %{"error" => %{"message" => message}} when is_binary(message) and message != "" -> message
        %{"message" => message} when is_binary(message) and message != "" -> message
        body when is_binary(body) and body != "" -> body
        _ -> "HTTP 429"
      end

    ReqLLM.Error.API.Request.exception(
      reason: reason,
      status: 429,
      response_body: response_body,
      headers: state.headers
    )
  end

  defp decode_rate_limit_body(""), do: ""

  defp decode_rate_limit_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp log_retry(reason, attempt, max_retries, delay_ms) do
    if delay_ms > 0 do
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
