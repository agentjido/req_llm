defmodule ReqLLM.Providers.OpenAI.OAuth do
  @moduledoc false

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @token_url "https://auth.openai.com/oauth/token"
  @jwt_claim_path "https://api.openai.com/auth"

  @spec refresh(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def refresh(credentials, opts) when is_map(credentials) do
    http_options = Keyword.get(opts, :oauth_http_options, [])
    refresh_token = credentials[:refresh]

    case Req.post(
           [
             url: @token_url,
             headers: [{"content-type", "application/x-www-form-urlencoded"}],
             form: [
               grant_type: "refresh_token",
               refresh_token: refresh_token,
               client_id: @client_id
             ]
           ] ++ http_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_refresh_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, refresh_error(status, body)}

      {:error, exception} ->
        {:error, "OpenAI OAuth refresh failed: #{Exception.message(exception)}"}
    end
  end

  defp decode_refresh_body(body) do
    payload = ensure_map(body)
    access_token = payload["access_token"]
    refresh_token = payload["refresh_token"]
    expires_in = payload["expires_in"]

    cond do
      blank?(access_token) ->
        {:error, "OpenAI OAuth refresh response did not include access_token"}

      blank?(refresh_token) ->
        {:error, "OpenAI OAuth refresh response did not include refresh_token"}

      not is_number(expires_in) ->
        {:error, "OpenAI OAuth refresh response did not include expires_in"}

      true ->
        {:ok,
         %{
           "type" => "oauth",
           "access" => access_token,
           "refresh" => refresh_token,
           "expires" => System.system_time(:millisecond) + round(expires_in * 1000),
           "accountId" => account_id_from_token(access_token)
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
        "OpenAI OAuth refresh failed with status #{status}: #{message}"

      %{"error" => message} when is_binary(message) ->
        "OpenAI OAuth refresh failed with status #{status}: #{message}"

      %{"message" => message} when is_binary(message) ->
        "OpenAI OAuth refresh failed with status #{status}: #{message}"

      _ ->
        "OpenAI OAuth refresh failed with status #{status}"
    end
  end

  @spec account_id_from_token(String.t() | nil) :: String.t() | nil
  def account_id_from_token(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        with {:ok, decoded} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(decoded),
             %{"chatgpt_account_id" => account_id} when is_binary(account_id) <-
               get_in(claims, [@jwt_claim_path]) do
          account_id
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def account_id_from_token(_token), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
