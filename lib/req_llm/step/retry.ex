defmodule ReqLLM.Step.Retry do
  @moduledoc """
  Req step that handles automatic retries for transient failures.

  This step configures Req's built-in retry mechanism to automatically retry
  requests that fail for a reason likely to succeed on retry. The policy is
  Req's `:transient` set, plus 529, the overloaded response Anthropic, Bedrock and TypeSafe document:

  * Socket closed errors (`:closed`)
  * Connection timeout errors (`:timeout`)
  * Connection refused errors (`:econnrefused`)
  * HTTP 408, 429, 500, 502, 503, 504 and 529 responses

  Transport errors typically indicate temporary network issues that resolve quickly,
  so they are retried instantly (with no delay) up to 3 times.

  ## Usage

      request
      |> ReqLLM.Step.Retry.attach()

  ## Retry Behavior

  - **Max retries**: 3 attempts (4 total requests including initial); `:max_retries`
    overrides it and `0` disables retries
  - **Retry delay**: 0ms for transport errors; the `Retry-After` header when the
    response carries one, otherwise exponential backoff with jitter (about 1s, 2s, 4s)
  - **Retryable errors**: the list above, whether they arrive as a bare
    `Req.TransportError` / `Req.Response` or wrapped in a `ReqLLM.Error.API.Request`;
    `:retry_statuses` replaces the HTTP status list, and `[]` retries transport errors only
  - **Non-retryable errors**: application errors and every other HTTP status

  ## Examples

      # Attach retry logic to a request
      request
      |> ReqLLM.Step.Retry.attach()
      |> Req.request()

      # A request that fails with {:error, %Req.TransportError{reason: :closed}}
      # or a 503 response is retried up to 3 times before giving up.

      # Retry rate limits only, and leave server errors to a caller-side fallback
      request
      |> ReqLLM.Step.Retry.attach(retry_statuses: [429, 529])
      |> Req.request()
  """

  @transient_reasons [:closed, :timeout, :econnrefused]
  @transient_statuses [408, 429, 500, 502, 503, 504, 529]

  @doc """
  Attaches the Retry configuration to a Req request struct.

  ## Parameters
  - `req` - The Req request struct
  - `opts` - Options keyword list, may contain `:max_retries` (defaults to 3) and
    `:retry_statuses`, the HTTP statuses to retry (defaults to
    `#{inspect(@transient_statuses)}`)

  ## Returns
  - Updated Req request struct with the step attached
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, Map.get(req.options, :max_retries, 3))

    retry_statuses =
      Keyword.get(opts, :retry_statuses) ||
        Req.Request.get_private(req, :req_llm_retry_statuses, @transient_statuses)

    req
    |> Req.Request.put_private(:req_llm_retry_statuses, retry_statuses)
    |> Req.Request.merge_options(
      retry: &should_retry?/2,
      max_retries: max_retries,
      # Req raises when :retry_delay is set and the retry function answers {:delay, ms}.
      retry_log_level: false
    )
    |> Req.Request.append_request_steps(llm_retry_attempt: &mark_attempt_start/1)
  end

  @doc false
  @spec mark_attempt_start(Req.Request.t()) :: Req.Request.t()
  def mark_attempt_start(request) do
    Req.Request.put_private(request, :req_llm_attempt_started_at, System.monotonic_time())
  end

  @doc """
  Determines if a request should be retried based on the error type.

  This function is used by Req's built-in retry mechanism. It returns one of:
  - `true` - Retry with the configured delay
  - `{:delay, milliseconds}` - Retry with a specific delay
  - `false` - Do not retry

  For transient transport errors, we return `{:delay, 0}` for instant retry.
  For HTTP 408, 429, 500, 502, 503, 504 and 529 responses, the delay is the
  `Retry-After` header when present, otherwise exponential backoff with jitter.
  The `:retry_statuses` option of `attach/2` replaces that status list.

  ## Parameters

  - `request` - The Req.Request struct, read for the retry count and retry statuses
  - `response_or_exception` - Either a Req.Response or an Exception

  ## Returns

  `{:delay, milliseconds}` if the error is retryable, `false` otherwise

  ## Examples

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %Req.TransportError{reason: :closed})
      {:delay, 0}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %Req.TransportError{reason: :timeout})
      {:delay, 0}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %ReqLLM.Error.API.Request{cause: %Req.TransportError{reason: :closed}})
      {:delay, 0}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, Req.Response.new(status: 503, headers: [{"retry-after", "2"}]))
      {:delay, 2000}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %RuntimeError{})
      false
  """
  @spec should_retry?(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          boolean() | {:delay, non_neg_integer()}
  def should_retry?(request, %Req.TransportError{reason: reason})
      when reason in @transient_reasons do
    retry(request, 0, nil)
  end

  def should_retry?(request, %Req.Response{status: status} = response)
      when is_integer(status) do
    retry_status(request, status, fn -> Req.Response.get_retry_after(response) end)
  end

  def should_retry?(request, %ReqLLM.Error.API.Request{status: status, headers: headers})
      when is_integer(status) do
    retry_status(request, status, fn -> retry_after(headers) end)
  end

  # ReqLLM.Step.Error wraps a transport error that hits a stale pooled connection.
  def should_retry?(request, %ReqLLM.Error.API.Request{
        cause: %{__struct__: mod, reason: reason}
      })
      when mod in [Finch.TransportError, Mint.TransportError, Req.TransportError] and
             reason in @transient_reasons do
    retry(request, 0, nil)
  end

  def should_retry?(_request, _response_or_exception), do: false

  defp retry_status(request, status, delay_fun) do
    if status in Req.Request.get_private(request, :req_llm_retry_statuses, @transient_statuses) do
      retry(request, delay_fun.(), status)
    else
      false
    end
  end

  defp retry(request, delay, http_status) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    max_retries = Req.Request.get_option(request, :max_retries, 3)
    started_at = Req.Request.get_private(request, :req_llm_attempt_started_at)
    delay = delay || backoff(retry_count)

    duration =
      if is_integer(started_at) do
        System.monotonic_time() - started_at
      else
        0
      end

    if retry_count < max_retries do
      ReqLLM.Telemetry.retry_request(ReqLLM.Telemetry.request_context(request), %{
        attempt: retry_count + 1,
        next_attempt: retry_count + 2,
        max_retries: max_retries,
        delay: delay,
        duration: duration,
        http_status: http_status
      })
    end

    {:delay, delay}
  end

  # Req's own curve: about 0.95 s, 1.9 s, 3.8 s.
  defp backoff(retry_count) do
    trunc(Integer.pow(2, retry_count) * 1000 * (1 - 0.1 * :rand.uniform()))
  end

  defp retry_after(nil), do: nil
  defp retry_after(headers), do: Req.Response.get_retry_after(Req.Response.new(headers: headers))
end
