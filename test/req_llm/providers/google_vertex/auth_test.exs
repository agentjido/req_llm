defmodule ReqLLM.Providers.GoogleVertex.AuthTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.GoogleVertex.Auth

  @env_vars [
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_APPLICATION_CREDENTIALS_JSON",
    "CLOUDSDK_CONFIG"
  ]

  setup do
    ReqLLM.Test.Env.isolate!(@env_vars)
  end

  describe "fetch_access_token/2 with ADC" do
    test "uses authorized_user credentials from GOOGLE_APPLICATION_CREDENTIALS" do
      path = write_credentials("authorized-user", authorized_user_credentials())
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", path)

      {:ok, token} = Auth.fetch_access_token(:adc, http_client: refresh_token_http_client())

      assert token.token == "adc-access-token"
      assert token.expires_at > System.system_time(:second)
    end

    test "applies a safety margin to Goth-reported token expiry" do
      path = write_credentials("authorized-user", authorized_user_credentials())
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", path)

      now = System.system_time(:second)
      {:ok, token} = Auth.fetch_access_token(:adc, http_client: refresh_token_http_client())

      # The http client reports expires_in: 3600; the cached expiry must be
      # at least 5 minutes earlier so tokens are never served moments before
      # they die.
      assert token.expires_at <= now + 3600 - 300 + 5
      assert token.expires_at >= now + 3600 - 300 - 5
    end

    test "uses authorized_user credentials from GOOGLE_APPLICATION_CREDENTIALS_JSON" do
      System.put_env(
        "GOOGLE_APPLICATION_CREDENTIALS_JSON",
        Jason.encode!(authorized_user_credentials())
      )

      {:ok, token} = Auth.fetch_access_token(:adc, http_client: refresh_token_http_client())

      assert token.token == "adc-access-token"
    end

    test "uses the well-known gcloud ADC file" do
      root = Path.join(System.tmp_dir!(), "req_llm_gcloud_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      path = Path.join(root, "application_default_credentials.json")
      File.write!(path, Jason.encode!(authorized_user_credentials()))

      {:ok, token} =
        Auth.fetch_access_token(:adc,
          config_root_dir: root,
          http_client: refresh_token_http_client()
        )

      assert token.token == "adc-access-token"
    end

    test "honors CLOUDSDK_CONFIG when locating the well-known gcloud ADC file" do
      root =
        Path.join(System.tmp_dir!(), "req_llm_cloudsdk_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      path = Path.join(root, "application_default_credentials.json")
      File.write!(path, Jason.encode!(authorized_user_credentials()))
      System.put_env("CLOUDSDK_CONFIG", root)

      {:ok, token} = Auth.fetch_access_token(:adc, http_client: refresh_token_http_client())

      assert token.token == "adc-access-token"
    end

    test "ignores empty credential env vars" do
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", "")
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS_JSON", "")

      root = Path.join(System.tmp_dir!(), "req_llm_gcloud_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      path = Path.join(root, "application_default_credentials.json")
      File.write!(path, Jason.encode!(authorized_user_credentials()))

      {:ok, token} =
        Auth.fetch_access_token(:adc,
          config_root_dir: root,
          http_client: refresh_token_http_client()
        )

      assert token.token == "adc-access-token"
    end

    test "falls back to metadata credentials" do
      root =
        Path.join(System.tmp_dir!(), "req_llm_empty_gcloud_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)

      {:ok, token} =
        Auth.fetch_access_token(:adc,
          config_root_dir: root,
          http_client: metadata_http_client()
        )

      assert token.token == "metadata-access-token"
    end

    test "returns a clear error for impersonated service account ADC files" do
      path =
        write_credentials("impersonated-service-account", %{
          "type" => "impersonated_service_account"
        })

      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", path)

      assert {:error, reason} =
               Auth.fetch_access_token(:adc, http_client: refresh_token_http_client())

      assert reason =~ "impersonated_service_account credentials are not supported"
    end
  end

  describe "fetch_access_token/2 with explicit service accounts" do
    test "rejects non-service-account credential maps before JWT signing" do
      assert {:error, reason} =
               Auth.fetch_access_token({:service_account, authorized_user_credentials()})

      assert reason =~ "expected type service_account"
    end

    test "rejects service-account credentials missing private key" do
      credentials = %{"type" => "service_account", "client_email" => "test@example.com"}

      assert {:error, reason} = Auth.fetch_access_token({:service_account, credentials})

      assert reason =~ "missing required client_email or private_key"
    end
  end

  defp authorized_user_credentials do
    %{
      "type" => "authorized_user",
      "client_id" => "client-id",
      "client_secret" => "client-secret",
      "refresh_token" => "refresh-token"
    }
  end

  defp refresh_token_http_client do
    fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://www.googleapis.com/oauth2/v4/token"
      assert {"Content-Type", "application/x-www-form-urlencoded"} in opts[:headers]

      body = URI.decode_query(opts[:body])
      assert body["grant_type"] == "refresh_token"
      assert body["refresh_token"] == "refresh-token"
      assert body["client_id"] == "client-id"
      assert body["client_secret"] == "client-secret"

      {:ok,
       %{
         status: 200,
         headers: [],
         body:
           Jason.encode!(%{
             "access_token" => "adc-access-token",
             "expires_in" => 3600,
             "token_type" => "Bearer"
           })
       }}
    end
  end

  defp metadata_http_client do
    fn opts ->
      assert opts[:method] == :get

      assert opts[:url] ==
               "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

      assert {"metadata-flavor", "Google"} in opts[:headers]

      {:ok,
       %{
         status: 200,
         headers: [],
         body:
           Jason.encode!(%{
             "access_token" => "metadata-access-token",
             "expires_in" => 3600,
             "token_type" => "Bearer"
           })
       }}
    end
  end

  defp write_credentials(name, credentials) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(credentials))
    path
  end
end
