defmodule ReqLLM.Step.Retry do
  @moduledoc """
  Req step that handles automatic retries for transient network errors.

  This step configures Req's built-in retry mechanism to automatically retry
  requests that fail due to transient network issues that are likely to succeed
  on immediate retry:

  * Socket closed errors (`:closed`)
  * Connection timeout errors (`:timeout`)
  * Connection refused errors (`:econnrefused`)

  These errors typically indicate temporary network issues that resolve quickly,
  so they are retried instantly (with no delay) up to 3 times.

  ## Usage

      request
      |> ReqLLM.Step.Retry.attach()

  ## Retry Behavior

  - **Max retries**: 3 attempts (4 total requests including initial)
  - **Retry delay**: 0ms (instant retry)
  - **Retryable errors**: Only transient `Req.TransportError` types
  - **Non-retryable errors**: Application errors, HTTP errors, etc. are not retried

  ## Examples

      # Attach retry logic to a request
      request
      |> ReqLLM.Step.Retry.attach()
      |> Req.request()

      # The step will automatically retry on socket closed errors
      # If a request fails with {:error, %Req.TransportError{reason: :closed}},
      # it will be retried up to 3 times before giving up.
  """

  @doc """
  Attaches the Retry configuration to a Req request struct.


  ## Parameters
  - `req` - The Req request struct
  - `opts` - Options keyword list, may contain `:max_retries` (defaults to 3)

  ## Returns
  - Updated Req request struct with the step attached
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    req
    |> Req.Request.merge_options(
      retry: &should_retry?/2,
      max_retries: max_retries,
      # Don't set retry_delay since should_retry?/2 returns {:delay, ms}
      # Setting both causes ArgumentError in Req 0.5.15+
      retry_log_level: false
    )
  end

  @doc """
  Determines if a request should be retried based on the error type.

  This function is used by Req's built-in retry mechanism. It returns one of:
  - `true` - Retry with the configured delay
  - `{:delay, milliseconds}` - Retry with a specific delay
  - `false` - Do not retry

  For transient network errors, we return `{:delay, 0}` for instant retry.

  ## Parameters

  - `_request` - The Req.Request struct (unused but available for extension)
  - `response_or_exception` - Either a Req.Response or an Exception

  ## Returns

  `{:delay, 0}` if the error is retryable (instant retry), `false` otherwise

  ## Examples

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %Req.TransportError{reason: :closed})
      {:delay, 0}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %Req.TransportError{reason: :timeout})
      {:delay, 0}

      iex> ReqLLM.Step.Retry.should_retry?(%Req.Request{}, %RuntimeError{})
      false
  """
  @spec should_retry?(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          boolean() | {:delay, non_neg_integer()}
  def should_retry?(_request, %Req.TransportError{reason: reason})
      when reason in [:closed, :timeout, :econnrefused] do
    {:delay, 0}
  end

  def should_retry?(_request, _response_or_exception), do: false
end
