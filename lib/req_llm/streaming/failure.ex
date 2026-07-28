defmodule ReqLLM.Streaming.Failure do
  @moduledoc false

  alias ReqLLM.MapAccess

  require Logger

  @retryable_transport_reasons [:closed, :timeout, :econnrefused, :pool_not_available]

  @type classification ::
          {:api, non_neg_integer(), term() | nil, boolean()}
          | {:transport, term(), boolean()}
          | :cancelled
          | :unknown
  @type api_error :: %ReqLLM.Error.API.Request{}

  @spec classify(term()) :: classification()
  def classify(%ReqLLM.Error.API.Request{status: status} = error) when is_integer(status) do
    provider_code = error.provider_code || provider_code(error.response_body)
    retryable = boolean_or_default(error.retryable, retryable_status?(status))
    {:api, status, provider_code, retryable}
  end

  def classify(%ReqLLM.Error.API.Request{cause: cause}) when not is_nil(cause) do
    classify(cause)
  end

  def classify(%Finch.TransportError{} = error) do
    transport_classification(transport_reason(error))
  end

  def classify(%{__struct__: module, reason: reason})
      when module in [Mint.TransportError, Req.TransportError, Finch.Error] do
    transport_classification(reason)
  end

  def classify(reason) when reason in [:cancelled, :canceled], do: :cancelled

  def classify({wrapper, reason})
      when wrapper in [:error, :exit, :throw, :shutdown, :http_task_failed] do
    classify(reason)
  end

  def classify(_reason), do: :unknown

  @spec log(term()) :: classification()
  def log(reason) do
    case classify(reason) do
      {:api, status, provider_code, retryable} = classification ->
        Logger.warning(
          "Streaming provider/API request failed: " <>
            "status=#{status}, " <>
            "provider_code=#{inspect(provider_code)}, " <>
            "retryable=#{retryable}, " <>
            "reason=#{inspect(reason)}"
        )

        classification

      {:transport, transport_reason, retryable} = classification ->
        Logger.error(
          "Finch streaming transport failed: " <>
            "reason=#{inspect(transport_reason)}, " <>
            "retryable=#{retryable}, " <>
            "error=#{inspect(reason)}"
        )

        classification

      :cancelled ->
        :cancelled

      :unknown ->
        Logger.error("Streaming request failed: #{inspect(reason)}")
        :unknown
    end
  end

  @spec api_error(non_neg_integer(), term(), list(), keyword()) :: api_error()
  def api_error(status, body, headers, opts \\ []) when is_integer(status) do
    response_body = normalize_response_body(body)
    error_body = error_body(response_body)

    ReqLLM.Error.API.Request.exception(
      reason: error_message(error_body, status, Keyword.get(opts, :use_body_as_reason?, false)),
      status: status,
      response_body: error_body,
      headers: headers,
      provider_code: provider_code(error_body),
      retryable: retryable_status?(status)
    )
  end

  defp transport_classification(reason) do
    {:transport, reason, reason in @retryable_transport_reasons}
  end

  defp transport_reason(%Finch.TransportError{source: source, reason: reason}) do
    case source do
      %Mint.TransportError{reason: source_reason} -> source_reason
      _ -> reason
    end
  end

  defp normalize_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp normalize_response_body(body), do: body

  defp error_body(body) when is_map(body) do
    case MapAccess.get(body, :error) do
      error when is_map(error) -> error
      _other -> body
    end
  end

  defp error_body(body), do: body

  defp error_message(body, status, _use_body_as_reason?) when is_map(body) do
    case MapAccess.get(body, :message) do
      message when is_binary(message) and message != "" -> message
      _other -> "HTTP #{status}"
    end
  end

  defp error_message(body, _status, true) when is_binary(body) and body != "", do: body
  defp error_message(_body, status, _use_body_as_reason?), do: "HTTP #{status}"

  defp provider_code(body) when is_map(body) do
    MapAccess.get(body, :code) || MapAccess.get(body, :type)
  end

  defp provider_code(_body), do: nil

  defp retryable_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_status?(status) when status in 500..599, do: true
  defp retryable_status?(_status), do: false

  defp boolean_or_default(value, _default) when is_boolean(value), do: value
  defp boolean_or_default(_value, default), do: default
end
