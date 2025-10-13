defmodule ReqLLM.Step.Error do
  @moduledoc """
  Req step that integrates with Splode error handling.

  This step converts HTTP error responses to structured ReqLLM.Error exceptions
  and handles common API error patterns. It processes both regular HTTP errors
  and API-specific error responses.

  ## Usage

      request
      |> ReqLLM.Step.Error.attach()

  The step handles various HTTP status codes and converts them to appropriate
  ReqLLM.Error types:

  - 400: Bad Request → API.Request error
  - 401: Unauthorized → API.Request error with authentication context
  - 403: Forbidden → API.Request error with authorization context
  - 404: Not Found → API.Request error
  - 429: Rate Limited → API.Request error with rate limit context
  - 500+: Server Error → API.Request error with server context

  ## Error Structure

  All errors include:
  - `status` - HTTP status code
  - `reason` - Human-readable error description
  - `response_body` - Raw API response (if available)
  - `request_body` - Original request body (if available)
  - `cause` - Underlying error cause (if available)

  """

  require ReqLLM.Debug, as: Debug

  @type api_error :: %ReqLLM.Error.API.Request{}

  @doc """
  Attaches the Splode error handling step to a Req request struct.

  ## Parameters
    - `req` - The Req request struct

  ## Returns
    - Updated Req request struct with the step attached

  """
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(req) do
    Req.Request.append_error_steps(req, splode_errors: &__MODULE__.handle/1)
  end

  @doc false
  @spec handle({Req.Request.t(), Req.Response.t() | Exception.t()}) ::
          {Req.Request.t(), api_error()}
  def handle({request, %Req.Response{} = response}) do
    error = convert_response_to_error(request, response)
    {request, error}
  end

  def handle({request, exception}) when is_exception(exception) do
    error = convert_exception_to_error(request, exception)
    {request, error}
  end

  @spec convert_response_to_error(Req.Request.t(), Req.Response.t()) :: api_error()
  defp convert_response_to_error(request, response) do
    reason = determine_error_reason(response)

    ReqLLM.Error.API.Request.exception(
      reason: reason,
      status: response.status,
      response_body: response.body,
      request_body: request.body,
      cause: nil
    )
  end

  @spec convert_exception_to_error(Req.Request.t(), Exception.t()) :: api_error()
  defp convert_exception_to_error(request, %ReqLLM.Error.API.Response{} = exception) do
    api_message =
      case exception.response_body do
        nil -> nil
        body -> extract_api_error_message(body)
      end

    reason =
      if is_binary(api_message) and api_message != "" do
        "#{Exception.message(exception)}: #{api_message}"
      else
        Exception.message(exception)
      end

    Debug.dbug(
      fn ->
        "OpenAI error response (#{exception.status}): #{inspect(exception.response_body)}"
      end,
      component: :error
    )

    ReqLLM.Error.API.Request.exception(
      reason: reason,
      status: exception.status,
      response_body: exception.response_body,
      request_body: request.body,
      cause: exception
    )
  end

  defp convert_exception_to_error(request, exception) do
    reason = Exception.message(exception)

    ReqLLM.Error.API.Request.exception(
      reason: reason,
      status: nil,
      response_body: nil,
      request_body: request.body,
      cause: exception
    )
  end

  @error_messages %{
    400 => "Bad Request - Invalid parameters or malformed request",
    401 => "Unauthorized - Invalid or missing API key",
    403 => "Forbidden - Insufficient permissions or quota exceeded",
    404 => "Not Found - Endpoint or resource not found",
    429 => "Rate Limited - Too many requests"
  }

  @spec determine_error_reason(Req.Response.t()) :: String.t()
  defp determine_error_reason(%{status: status, body: body}) do
    api_message = extract_api_error_message(body)

    cond do
      api_message -> api_message
      status >= 500 -> "Server Error - Internal API error"
      true -> Map.get(@error_messages, status, "HTTP Error #{status}")
    end
  end

  @spec extract_api_error_message(any()) :: String.t() | nil
  defp extract_api_error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> extract_api_error_message(decoded)
      {:error, _} -> nil
    end
  end

  defp extract_api_error_message(%{"error" => %{"message" => message}}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(%{"error" => message}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(%{"message" => message}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(%{"detail" => message}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(%{"details" => message}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(%{"error_description" => message}) when is_binary(message) do
    message
  end

  defp extract_api_error_message(_), do: nil
end
