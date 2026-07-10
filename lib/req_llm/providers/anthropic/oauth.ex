defmodule ReqLLM.Providers.Anthropic.OAuth do
  @moduledoc false

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @token_url "https://platform.claude.com/v1/oauth/token"

  @spec refresh(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def refresh(credentials, opts) when is_map(credentials) do
    refresh_token = credentials[:refresh]

    if blank?(refresh_token) do
      {:error, "Anthropic OAuth credentials are missing a refresh token"}
    else
      http_options = Keyword.get(opts, :oauth_http_options, [])

      case Req.post(
             [
               url: @token_url,
               headers: [{"content-type", "application/json"}],
               json: %{
                 grant_type: "refresh_token",
                 client_id: @client_id,
                 refresh_token: refresh_token
               }
             ] ++ http_options
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          decode_refresh_body(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, refresh_error(status, body)}

        {:error, exception} ->
          {:error, "Anthropic OAuth refresh failed: #{Exception.message(exception)}"}
      end
    end
  end

  defp decode_refresh_body(body) do
    payload = ensure_map(body)
    access_token = payload["access_token"]
    refresh_token = payload["refresh_token"]
    expires_in = payload["expires_in"]

    cond do
      blank?(access_token) ->
        {:error, "Anthropic OAuth refresh response did not include access_token"}

      blank?(refresh_token) ->
        {:error, "Anthropic OAuth refresh response did not include refresh_token"}

      not is_number(expires_in) ->
        {:error, "Anthropic OAuth refresh response did not include expires_in"}

      true ->
        {:ok,
         %{
           "type" => "oauth",
           "access" => access_token,
           "refresh" => refresh_token,
           "expires" => System.system_time(:millisecond) + round(expires_in * 1000)
         }}
    end
  end

  defp ensure_map(body) when is_map(body), do: body

  defp ensure_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} -> payload
      {:error, _error} -> %{}
    end
  end

  defp ensure_map(_body), do: %{}

  defp refresh_error(status, body) do
    case ensure_map(body) do
      %{"error" => %{"message" => message}} when is_binary(message) ->
        "Anthropic OAuth refresh failed with status #{status}: #{message}"

      %{"error" => message} when is_binary(message) ->
        "Anthropic OAuth refresh failed with status #{status}: #{message}"

      %{"message" => message} when is_binary(message) ->
        "Anthropic OAuth refresh failed with status #{status}: #{message}"

      _ ->
        "Anthropic OAuth refresh failed with status #{status}"
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
