defmodule ReqLLM.Providers.GoogleVertex.Auth do
  @moduledoc """
  Google Cloud OAuth2 authentication for Vertex AI.

  Supports Application Default Credentials (ADC) and explicit service account
  credentials.
  """

  alias ReqLLM.Provider.Utils
  alias ReqLLM.Providers.GoogleVertex.GothAdapter

  require Logger

  @token_uri "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @token_lifetime_seconds 3600
  @safety_margin_seconds 300

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
    case fetch_access_token(service_account) do
      {:ok, %{token: token}} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Get an OAuth2 access token and expiry metadata.

  Accepts `:adc`, `{:service_account, credentials}`, or the legacy direct
  service account credential formats accepted by `get_access_token/1`.
  """
  def fetch_access_token(source, opts \\ [])

  def fetch_access_token(:adc, opts) do
    Logger.debug("Getting GCP access token from Application Default Credentials")

    with {:ok, source} <- resolve_adc_source(opts) do
      fetch_access_token(source, opts)
    end
  end

  def fetch_access_token({:service_account, service_account}, _opts) do
    fetch_service_account_access_token(service_account)
  end

  def fetch_access_token({type, _credentials} = source, opts)
      when type in [:refresh_token, :workload_identity] do
    opts
    |> goth_config(source)
    |> fetch_goth_token()
  end

  def fetch_access_token(:metadata = source, opts) do
    opts
    |> goth_config(source)
    |> fetch_goth_token()
  end

  def fetch_access_token(service_account, _opts) do
    fetch_service_account_access_token(service_account)
  end

  @doc false
  def request_with_finch(options) do
    {method, options} = Keyword.pop!(options, :method)
    {url, options} = Keyword.pop!(options, :url)
    {headers, options} = Keyword.pop!(options, :headers)
    {body, options} = Keyword.pop(options, :body, "")

    method
    |> Finch.build(url, headers, body || "")
    |> Finch.request(ReqLLM.Application.finch_name(), options)
  end

  defp fetch_service_account_access_token(service_account) do
    Logger.debug("Getting GCP access token")

    with {:ok, service_account} <- read_service_account(service_account),
         :ok <- validate_service_account(service_account),
         {:ok, jwt} <- create_jwt(service_account),
         {:ok, token_response} <- exchange_jwt_for_token(jwt) do
      access_token = Map.get(token_response, "access_token")
      Logger.debug("Successfully obtained GCP access token")
      {:ok, %{token: access_token, expires_at: service_account_token_expires_at(token_response)}}
    else
      {:error, reason} = error ->
        Logger.error("Failed to get GCP access token: #{inspect(reason)}")
        error
    end
  end

  defp read_service_account(service_account) when is_map(service_account) do
    {:ok, Utils.stringify_keys(service_account)}
  end

  defp read_service_account(path_or_json) when is_binary(path_or_json) do
    if File.exists?(path_or_json) do
      read_service_account_file(path_or_json)
    else
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

  defp validate_service_account(%{"type" => type}) when type not in [nil, "service_account"] do
    {:error,
     "Invalid service account credentials: expected type service_account, got #{inspect(type)}"}
  end

  defp validate_service_account(%{"client_email" => email, "private_key" => key})
       when is_binary(email) and is_binary(key) do
    :ok
  end

  defp validate_service_account(_service_account) do
    {:error,
     "Invalid service account credentials: missing required client_email or private_key fields"}
  end

  defp create_jwt(service_account) do
    now = System.system_time(:second)
    exp = now + @token_lifetime_seconds

    header = %{
      "alg" => "RS256",
      "typ" => "JWT"
    }

    claims = %{
      "iss" => service_account["client_email"],
      "scope" => @scope,
      "aud" => @token_uri,
      "exp" => exp,
      "iat" => now
    }

    header_b64 = base64url_encode(Jason.encode!(header))
    claims_b64 = base64url_encode(Jason.encode!(claims))
    message = "#{header_b64}.#{claims_b64}"

    case sign_message(message, service_account["private_key"]) do
      {:ok, signature} ->
        jwt = "#{message}.#{signature}"
        {:ok, jwt}

      error ->
        error
    end
  end

  defp sign_message(message, private_key_pem) do
    [entry] = :public_key.pem_decode(private_key_pem)
    private_key = :public_key.pem_entry_decode(entry)

    signature = :public_key.sign(message, :sha256, private_key)

    signature_b64 = base64url_encode(signature)

    {:ok, signature_b64}
  rescue
    e -> {:error, "Failed to sign JWT: #{inspect(e)}"}
  end

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

  @doc false
  # Cheap check whether local ADC credentials appear to be configured, without
  # reading or validating them. Used by ReqLLM.Availability.
  def adc_credentials_present? do
    adc_location([]) != :metadata
  end

  @doc false
  # Identifies which local ADC credentials resolve_adc_source/1 would pick up,
  # so the token cache can key tokens per credential location instead of one
  # global ADC slot (a runtime credential swap must not serve stale tokens).
  def adc_cache_scope(opts \\ []) do
    case adc_location(opts) do
      {:json, json} -> {:json, :erlang.phash2(json)}
      location -> location
    end
  end

  defp resolve_adc_source(opts) do
    case adc_location(opts) do
      {:path, path} -> read_adc_file(path)
      {:json, json} -> json |> Jason.decode() |> adc_source_from_decode_result()
      :metadata -> {:ok, :metadata}
    end
  end

  # Single source of truth for ADC credential discovery order; everything else
  # (source resolution, cache scoping, availability) derives from it.
  defp adc_location(opts) do
    cond do
      path =
          Keyword.get(opts, :credentials_path) ||
            Utils.present_env("GOOGLE_APPLICATION_CREDENTIALS") ->
        {:path, path}

      json = Utils.present_env("GOOGLE_APPLICATION_CREDENTIALS_JSON") ->
        {:json, json}

      path = well_known_adc_path(opts) ->
        {:path, path}

      true ->
        :metadata
    end
  end

  defp read_adc_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, credentials} <- Jason.decode(content) do
      adc_source_from_credentials(credentials)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Failed to parse ADC credentials file #{path}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Failed to read ADC credentials file #{path}: #{inspect(reason)}"}
    end
  end

  defp adc_source_from_decode_result({:ok, credentials}),
    do: adc_source_from_credentials(credentials)

  defp adc_source_from_decode_result({:error, reason}) do
    {:error, "Failed to parse GOOGLE_APPLICATION_CREDENTIALS_JSON: #{Exception.message(reason)}"}
  end

  defp adc_source_from_credentials(%{"type" => "authorized_user"} = credentials) do
    {:ok, {:refresh_token, credentials}}
  end

  defp adc_source_from_credentials(%{"type" => "service_account"} = credentials) do
    {:ok, {:service_account, credentials}}
  end

  defp adc_source_from_credentials(%{"type" => "external_account"} = credentials) do
    {:ok, {:workload_identity, credentials}}
  end

  defp adc_source_from_credentials(%{"type" => "impersonated_service_account"}) do
    {:error, "ADC impersonated_service_account credentials are not supported by ReqLLM yet"}
  end

  defp adc_source_from_credentials(%{"private_key" => _, "client_email" => _} = credentials) do
    {:ok, {:service_account, credentials}}
  end

  defp adc_source_from_credentials(
         %{
           "refresh_token" => _,
           "client_id" => _,
           "client_secret" => _
         } = credentials
       ) do
    {:ok, {:refresh_token, credentials}}
  end

  defp adc_source_from_credentials(credentials) do
    {:error, "Unsupported ADC credential type: #{inspect(Map.get(credentials, "type"))}"}
  end

  defp well_known_adc_path(opts) do
    root_dir = Keyword.get(opts, :config_root_dir) || gcloud_config_root_dir()
    path = Path.join(root_dir, "application_default_credentials.json")

    if File.regular?(path), do: path
  end

  defp gcloud_config_root_dir do
    Utils.present_env("CLOUDSDK_CONFIG") ||
      case :os.type() do
        {:win32, _} ->
          Path.join([System.get_env("APPDATA") || "", "gcloud"])

        {:unix, _} ->
          Path.join([System.get_env("HOME") || "", ".config/gcloud"])
      end
  end

  defp goth_config(opts, source) do
    http_client =
      opts
      |> Keyword.get(:http_client, {&request_with_finch/1, []})
      |> normalize_goth_http_client()

    [
      source: source,
      http_client: http_client
    ]
  end

  defp normalize_goth_http_client(fun) when is_function(fun, 1), do: {fun, []}
  defp normalize_goth_http_client({fun, opts}) when is_function(fun, 1), do: {fun, opts}
  defp normalize_goth_http_client(other), do: other

  defp fetch_goth_token(config) do
    case GothAdapter.fetch_token(config) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        {:ok, %{token: token, expires_at: expires_at - @safety_margin_seconds}}

      {:error, reason} ->
        {:error, "Failed to get ADC access token: #{Exception.message(reason)}"}
    end
  rescue
    error -> {:error, "Failed to get ADC access token: #{Exception.message(error)}"}
  end

  defp service_account_token_expires_at(%{"expires_in" => expires_in})
       when is_integer(expires_in) do
    System.system_time(:second) + max(expires_in - @safety_margin_seconds, 0)
  end

  defp service_account_token_expires_at(_token_response) do
    System.system_time(:second) + @token_lifetime_seconds - @safety_margin_seconds
  end

  defp base64url_encode(data) when is_binary(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end
end
