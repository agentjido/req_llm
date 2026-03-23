defmodule ReqLLM.Streaming.Retry do
  @moduledoc """
  Retry wrapper for Finch streaming requests.

  Streaming retries are intentionally conservative: only transient transport
  failures that happen before any response body data is emitted are retried.
  This avoids duplicating partial model output when a stream has already begun.
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

    do_stream(request, finch_name, acc, callback, stream_opts, stream_fun, max_retries, 0)
  end

  defp do_stream(
         request,
         finch_name,
         acc,
         callback,
         stream_opts,
         stream_fun,
         max_retries,
         attempt
       ) do
    initial_acc = %{callback_acc: acc, data_received?: false}
    wrapped_callback = fn event, wrapped_acc -> apply_callback(event, wrapped_acc, callback) end

    case stream_fun.(request, finch_name, initial_acc, wrapped_callback, stream_opts) do
      {:ok, %{callback_acc: callback_acc}} ->
        {:ok, callback_acc}

      {:error, reason, %{data_received?: false, callback_acc: callback_acc}}
      when attempt < max_retries ->
        maybe_retry(
          request,
          finch_name,
          acc,
          callback,
          stream_opts,
          stream_fun,
          max_retries,
          attempt,
          callback_acc,
          reason
        )

      {:error, reason, %{callback_acc: callback_acc}} ->
        {:error, reason, callback_acc}
    end
  end

  defp maybe_retry(
         request,
         finch_name,
         acc,
         callback,
         stream_opts,
         stream_fun,
         max_retries,
         attempt,
         callback_acc,
         reason
       ) do
    if retryable_reason?(reason) do
      log_retry(reason, attempt + 1, max_retries)

      do_stream(
        request,
        finch_name,
        acc,
        callback,
        stream_opts,
        stream_fun,
        max_retries,
        attempt + 1
      )
    else
      {:error, reason, callback_acc}
    end
  end

  defp apply_callback({:data, _} = event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc), data_received?: true}
  end

  defp apply_callback(event, %{callback_acc: callback_acc} = wrapped_acc, callback) do
    %{wrapped_acc | callback_acc: callback.(event, callback_acc)}
  end

  defp retryable_reason?(%Mint.TransportError{reason: reason}) when reason in @retryable_reasons,
    do: true

  defp retryable_reason?(%Req.TransportError{reason: reason}) when reason in @retryable_reasons,
    do: true

  defp retryable_reason?(_reason), do: false

  defp log_retry(reason, attempt, max_retries) do
    Logger.warning(
      "Retrying streaming request after transient transport error",
      reason: inspect(reason),
      attempt: attempt,
      max_retries: max_retries
    )
  end
end
