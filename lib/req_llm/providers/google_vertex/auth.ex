defmodule ReqLLM.Providers.GoogleVertex.Auth do
  @moduledoc """
  Google Cloud OAuth2 authentication for Vertex AI.

  Implements service account JWT-based authentication to obtain access tokens.
  """

  require Logger

  @token_uri "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @token_lifetime_seconds 3600

  @doc """
  Get an OAuth2 access token from a service account JSON file.

  Generates a fresh token on each call. Tokens are valid for 1 hour.

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  def get_access_token(service_account_json_path) do
    Logger.debug("Getting GCP access token from: #{service_account_json_path}")

    # Generate new token
    with {:ok, service_account} <- read_service_account(service_account_json_path),
         {:ok, jwt} <- create_jwt(service_account),
         {:ok, token_response} <- exchange_jwt_for_token(jwt) do
      access_token = Map.get(token_response, "access_token")
      Logger.debug("Successfully obtained GCP access token")
      {:ok, access_token}
    else
      {:error, reason} = error ->
        Logger.error("Failed to get GCP access token: #{inspect(reason)}")
        error
    end
  end

  # Read and parse service account JSON file
  defp read_service_account(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, json} -> {:ok, json}
          {:error, reason} -> {:error, "Failed to parse service account JSON: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read service account file: #{inspect(reason)}"}
    end
  end

  # Create a signed JWT for service account authentication
  defp create_jwt(service_account) do
    now = System.system_time(:second)
    exp = now + @token_lifetime_seconds

    # JWT header
    header = %{
      "alg" => "RS256",
      "typ" => "JWT"
    }

    # JWT claims
    claims = %{
      "iss" => service_account["client_email"],
      "scope" => @scope,
      "aud" => @token_uri,
      "exp" => exp,
      "iat" => now
    }

    # Encode header and claims
    header_b64 = base64url_encode(Jason.encode!(header))
    claims_b64 = base64url_encode(Jason.encode!(claims))
    message = "#{header_b64}.#{claims_b64}"

    # Sign with private key
    case sign_message(message, service_account["private_key"]) do
      {:ok, signature} ->
        jwt = "#{message}.#{signature}"
        {:ok, jwt}

      error ->
        error
    end
  end

  # Sign a message with RSA SHA256
  defp sign_message(message, private_key_pem) do
    # Parse PEM private key
    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)

    # Sign the message
    signature = :public_key.sign(message, :sha256, private_key)

    # Base64url encode the signature
    signature_b64 = base64url_encode(signature)

    {:ok, signature_b64}
  rescue
    e -> {:error, "Failed to sign JWT: #{inspect(e)}"}
  end

  # Exchange JWT for access token
  defp exchange_jwt_for_token(jwt) do
    body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=#{jwt}"

    request =
      Req.new(
        url: @token_uri,
        method: :post,
        body: body,
        headers: [
          {"content-type", "application/x-www-form-urlencoded"}
        ]
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "Token exchange failed with status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Token exchange request failed: #{inspect(reason)}"}
    end
  end

  # Base64url encode (URL-safe base64 without padding)
  defp base64url_encode(data) when is_binary(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end
end
