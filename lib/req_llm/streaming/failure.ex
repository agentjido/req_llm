defmodule ReqLLM.Streaming.Failure do
  @moduledoc false

  require Logger

  @retryable_transport_reasons [:closed, :timeout, :econnrefused, :pool_not_available]

  @type category :: :api | :transport | :cancelled | :unknown
  @type classification :: %{
          category: category(),
          provider_code: term() | nil,
          retryable: boolean(),
          severity: Logger.level() | nil,
          status: non_neg_integer() | nil,
          transport_reason: term() | nil
        }
  @type api_error :: %ReqLLM.Error.API.Request{}

  @spec classify(term()) :: classification()
  def classify(%ReqLLM.Error.API.Request{status: status} = error) when is_integer(status) do
    %{
      category: :api,
      provider_code: error.provider_code || provider_code(error.response_body),
      retryable: boolean_or_default(error.retryable, retryable_status?(status)),
      severity: :warning,
      status: status,
      transport_reason: nil
    }
  end

  def classify(%ReqLLM.Error.API.Request{cause: cause}) when not is_nil(cause) do
    classify(cause)
  end

  def classify(%Finch.TransportError{} = error) do
    transport_classification(transport_reason(error))
  end

  def classify(%Mint.TransportError{reason: reason}) do
    transport_classification(reason)
  end

  def classify(%Req.TransportError{reason: reason}) do
    transport_classification(reason)
  end

  def classify(%Finch.Error{reason: reason}) do
    transport_classification(reason)
  end

  def classify(reason) when reason in [:cancelled, :canceled] do
    cancelled_classification()
  end

  def classify({wrapper, reason}) when wrapper in [:exit, :shutdown, :http_task_failed] do
    case classify(reason) do
      %{category: :unknown} -> unknown_classification()
      classification -> classification
    end
  end

  def classify(_reason), do: unknown_classification()

  @spec log(term()) :: classification()
  def log(reason) do
    classification = classify(reason)
    log_classification(classification, reason)
    classification
  end

  @spec api_error(non_neg_integer(), term(), list()) :: api_error()
  def api_error(status, body, headers) when is_integer(status) do
    response_body = normalize_response_body(body)

    ReqLLM.Error.API.Request.exception(
      reason: error_message(response_body, status),
      status: status,
      response_body: unwrap_error(response_body),
      headers: headers,
      provider_code: provider_code(response_body),
      retryable: retryable_status?(status)
    )
  end

  @spec provider_code(term()) :: term() | nil
  def provider_code(%{"error" => error}) when is_map(error), do: provider_code(error)
  def provider_code(%{error: error}) when is_map(error), do: provider_code(error)
  def provider_code(%{"code" => code}) when not is_nil(code), do: code
  def provider_code(%{code: code}) when not is_nil(code), do: code
  def provider_code(%{"type" => type}), do: type
  def provider_code(%{type: type}), do: type
  def provider_code(_body), do: nil

  @spec retryable_status?(non_neg_integer()) :: boolean()
  def retryable_status?(status) when status in [408, 409, 425, 429], do: true
  def retryable_status?(status) when status in 500..599, do: true
  def retryable_status?(_status), do: false

  defp log_classification(%{category: :api} = classification, reason) do
    Logger.warning(
      "Streaming provider/API request failed: " <>
        "status=#{classification.status}, " <>
        "provider_code=#{inspect(classification.provider_code)}, " <>
        "retryable=#{classification.retryable}, " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp log_classification(%{category: :transport} = classification, reason) do
    Logger.error(
      "Finch streaming transport failed: " <>
        "reason=#{inspect(classification.transport_reason)}, " <>
        "retryable=#{classification.retryable}, " <>
        "error=#{inspect(reason)}"
    )
  end

  defp log_classification(%{category: :cancelled}, _reason), do: :ok

  defp log_classification(%{category: :unknown}, reason) do
    Logger.error("Streaming request failed: #{inspect(reason)}")
  end

  defp transport_classification(reason) do
    %{
      category: :transport,
      provider_code: nil,
      retryable: reason in @retryable_transport_reasons,
      severity: :error,
      status: nil,
      transport_reason: reason
    }
  end

  defp cancelled_classification do
    %{
      category: :cancelled,
      provider_code: nil,
      retryable: false,
      severity: nil,
      status: nil,
      transport_reason: nil
    }
  end

  defp unknown_classification do
    %{
      category: :unknown,
      provider_code: nil,
      retryable: false,
      severity: :error,
      status: nil,
      transport_reason: nil
    }
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

  defp error_message(%{"error" => error}, status) when is_map(error) do
    error_message(error, status)
  end

  defp error_message(%{error: error}, status) when is_map(error) do
    error_message(error, status)
  end

  defp error_message(%{"message" => message}, _status)
       when is_binary(message) and message != "" do
    message
  end

  defp error_message(%{message: message}, _status) when is_binary(message) and message != "" do
    message
  end

  defp error_message(_body, status), do: "HTTP #{status}"

  defp unwrap_error(%{"error" => error}) when is_map(error), do: error
  defp unwrap_error(%{error: error}) when is_map(error), do: error
  defp unwrap_error(body), do: body

  defp boolean_or_default(value, _default) when is_boolean(value), do: value
  defp boolean_or_default(_value, default), do: default
end
