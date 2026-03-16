defmodule ReqLLM.Providers.GoogleVertex.Auth do
  @moduledoc """
  Google Cloud OAuth2 authentication for Vertex AI.

  Implements service account JWT-based authentication to obtain access tokens.
  """

  alias ReqLLM.Provider.Utils

  require Logger

  @token_uri "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @token_lifetime_seconds 3600

  @doc """
  Get an OAuth2 access token from service account credentials.

  Accepts credentials in multiple formats:
  - File path (string) - if file exists, reads and parses JSON file
  - JSON string (string) - if not a file, parses as JSON directly
  - Map - uses as-is (already parsed, normalizes atom keys to strings)

  Generates a fresh token on each call. Tokens are valid for 1 hour.

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  def get_access_token(service_account) do
    Logger.debug("Getting GCP access token")

    # Generate new token
    with {:ok, service_account} <- read_service_account(service_account),
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

  # Read and parse service account - accepts file path, JSON string, or map
  defp read_service_account(service_account) when is_map(service_account) do
    # Already parsed map - normalize to string keys
    {:ok, Utils.stringify_keys(service_account)}
  end

  defp read_service_account(path_or_json) when is_binary(path_or_json) do
    # Check if it's a file path first (more reliable than checking for "{")
    if File.exists?(path_or_json) do
      read_service_account_file(path_or_json)
    else
      # Not a file - try parsing as JSON string
      case Jason.decode(path_or_json) do
        {:ok, json} ->
          {:ok, json}

        {:error, _reason} ->
          {:error,
           "Invalid service account credentials: " <>
             "not a valid file path or JSON string (#{String.length(path_or_json)} chars)"}
      end
    end
  end

  defp read_service_account_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, json} ->
            {:ok, json}

          {:error, reason} ->
            {:error, "Failed to parse service account JSON: #{inspect(reason)}"}
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
        finch: ReqLLM.Application.finch_name(),
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
