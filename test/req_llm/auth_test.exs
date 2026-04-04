defmodule ReqLLM.AuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Auth
  alias ReqLLM.OAuth

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "req_llm_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "resolve/2 with access_token" do
    test "returns oauth credential when auth_mode is :oauth and access_token is provided" do
      assert {:ok,
              %{
                kind: :oauth_access_token,
                token: "my-oauth-token",
                source: :option
              }} = Auth.resolve(:anthropic, auth_mode: :oauth, access_token: "my-oauth-token")
    end

    test "returns oauth credential from provider_options access_token" do
      assert {:ok,
              %{
                kind: :oauth_access_token,
                token: "provider-token",
                source: :provider_options
              }} =
               Auth.resolve(:anthropic,
                 auth_mode: :oauth,
                 provider_options: [access_token: "provider-token"]
               )
    end

    test "top-level access_token takes precedence over provider_options" do
      assert {:ok, %{token: "top-level"}} =
               Auth.resolve(:anthropic,
                 auth_mode: :oauth,
                 access_token: "top-level",
                 provider_options: [access_token: "nested"]
               )
    end

    test "returns error for empty access_token" do
      assert {:error, msg} = Auth.resolve(:anthropic, auth_mode: :oauth, access_token: "")
      assert msg =~ "empty"
    end
  end

  describe "resolve/2 with api_key mode" do
    test "returns api_key credential with explicit api_key" do
      assert {:ok,
              %{
                kind: :api_key,
                token: "sk-test-key",
                source: :option,
                account_id: nil
              }} = Auth.resolve(:anthropic, api_key: "sk-test-key")
    end
  end

  describe "resolve!/2" do
    test "returns credential on success" do
      credential = Auth.resolve!(:anthropic, api_key: "sk-test-key")
      assert credential.kind == :api_key
      assert credential.token == "sk-test-key"
    end

    test "raises on failure" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Auth.resolve!(:anthropic, auth_mode: :oauth, access_token: "")
      end
    end
  end

  describe "resolve/2 with oauth files" do
    test "loads oauth credentials from oauth.json", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "anthropic" => %{
          "type" => "oauth",
          "access" => "oauth-file-access",
          "refresh" => "oauth-file-refresh",
          "expires" => future_expiry()
        }
      })

      assert {:ok, %{kind: :oauth_access_token, token: "oauth-file-access", source: :oauth_file}} =
               Auth.resolve(:anthropic, provider_options: [auth_mode: :oauth, oauth_file: path])
    end

    test "loads oauth credentials from auth.json alias", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "auth.json")

      write_oauth_file(path, %{
        "anthropic" => %{
          "type" => "oauth",
          "access" => "auth-file-access",
          "refresh" => "auth-file-refresh",
          "expires" => future_expiry()
        }
      })

      assert {:ok, %{kind: :oauth_access_token, token: "auth-file-access", source: :oauth_file}} =
               Auth.resolve(:anthropic, provider_options: [auth_mode: :oauth, auth_file: path])
    end
  end

  describe "OAuth.resolve/2 error handling" do
    test "rejects unsupported provider input types" do
      assert {:error, message} = OAuth.resolve("openai", [])
      assert message =~ "provider atom or model struct"
    end

    test "returns a helpful error for missing oauth files", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing.json")

      assert {:error, message} =
               OAuth.resolve(:openai, provider_options: [oauth_file: missing])

      assert message =~ "OAuth file not found"
      assert message =~ missing
    end

    test "returns a helpful error for invalid json payloads", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")
      File.write!(path, "{not valid json")

      assert {:error, message} =
               OAuth.resolve(:openai, provider_options: [oauth_file: path])

      assert message =~ "is not valid JSON"
    end

    test "rejects oauth files whose top-level payload is not a json object", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")
      write_oauth_file(path, [])

      assert {:error, message} =
               OAuth.resolve(:openai, provider_options: [oauth_file: path])

      assert message =~ "must contain a top-level JSON object"
    end

    test "rejects oauth files missing provider credentials", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")
      write_oauth_file(path, %{"anthropic" => %{"access" => "token"}})

      assert {:error, message} =
               OAuth.resolve(:openai, provider_options: [oauth_file: path])

      assert message =~ "does not contain credentials"
    end

    test "rejects oauth credentials with no access or refresh token", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")
      write_oauth_file(path, %{"openai" => %{"access" => " ", "refresh" => " "}})

      assert {:error, message} =
               OAuth.resolve(:openai, provider_options: [oauth_file: path])

      assert message =~ "do not include access or refresh tokens"
    end

    test "rejects expired credentials without refresh tokens", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "anthropic" => %{
          "access" => "expired-access",
          "expires" => past_expiry()
        }
      })

      assert {:error, message} =
               OAuth.resolve(:anthropic, provider_options: [oauth_file: path])

      assert message =~ "are expired and do not include a refresh token"
    end

    test "rejects refresh attempts for providers without refresh support", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "google" => %{
          "access" => "expired-access",
          "refresh" => "refresh-token",
          "expires" => past_expiry()
        }
      })

      assert {:error, message} =
               OAuth.resolve(:google, provider_options: [oauth_file: path])

      assert message =~ "does not support OAuth token refresh"
    end
  end

  defp write_oauth_file(path, payload) do
    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp future_expiry do
    System.system_time(:millisecond) + 60_000
  end

  defp past_expiry do
    System.system_time(:millisecond) - 60_000
  end
end
