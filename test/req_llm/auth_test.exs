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

  describe "resolve/2 with oauth files" do
    test "loads oauth credentials from oauth.json", %{tmp_dir: tmp_dir} do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => "oauth-file-access",
          "refresh" => "oauth-file-refresh",
          "expires" => future_expiry()
        }
      })

      assert {:ok, %{kind: :oauth_access_token, token: "oauth-file-access", source: :oauth_file}} =
               Auth.resolve(model, provider_options: [auth_mode: :oauth, oauth_file: path])
    end

    test "loads oauth credentials from auth.json alias", %{tmp_dir: tmp_dir} do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      path = Path.join(tmp_dir, "auth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => "auth-file-access",
          "refresh" => "auth-file-refresh",
          "expires" => future_expiry()
        }
      })

      assert {:ok, %{kind: :oauth_access_token, token: "auth-file-access", source: :oauth_file}} =
               Auth.resolve(model, provider_options: [auth_mode: :oauth, auth_file: path])
    end

    test "refreshes expired oauth credentials and persists them", %{tmp_dir: tmp_dir} do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => "expired-access",
          "refresh" => "refresh-token-123",
          "expires" => past_expiry()
        }
      })

      Req.Test.stub(ReqLLM.AuthOpenAIRefreshTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/oauth/token"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "refresh-token-123"
        assert params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"

        Req.Test.json(conn, %{
          "access_token" => "fresh-access-token",
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      end)

      assert {:ok,
              %{
                kind: :oauth_access_token,
                token: "fresh-access-token",
                source: :oauth_refresh
              }} =
               Auth.resolve(model,
                 provider_options: [
                   auth_mode: :oauth,
                   oauth_file: path,
                   oauth_http_options: [plug: {Req.Test, ReqLLM.AuthOpenAIRefreshTest}]
                 ]
               )

      refreshed =
        path
        |> File.read!()
        |> Jason.decode!()

      assert refreshed["openai-codex"]["access"] == "fresh-access-token"
      assert refreshed["openai-codex"]["refresh"] == "fresh-refresh-token"
      assert is_integer(refreshed["openai-codex"]["expires"])
      assert refreshed["openai-codex"]["expires"] > System.system_time(:millisecond)
    end
  end

  describe "OAuth.resolve/2 account id handling" do
    test "returns account id from oauth file credentials", %{tmp_dir: tmp_dir} do
      {:ok, model} = ReqLLM.model(%{provider: :openai_codex, id: "gpt-5.3-codex-spark"})
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_from_file"),
          "refresh" => "oauth-file-refresh",
          "expires" => future_expiry(),
          "accountId" => "acct_from_file"
        }
      })

      assert {:ok,
              %{
                token: token,
                source: :oauth_file,
                oauth_file: ^path,
                provider_key: "openai-codex",
                account_id: "acct_from_file"
              }} = OAuth.resolve(model, provider_options: [auth_mode: :oauth, oauth_file: path])

      assert is_binary(token)
    end

    test "derives account id from token when oauth file omits it", %{tmp_dir: tmp_dir} do
      {:ok, model} = ReqLLM.model(%{provider: :openai_codex, id: "gpt-5.3-codex-spark"})
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => jwt_with_account_id("acct_from_token"),
          "refresh" => "oauth-file-refresh",
          "expires" => future_expiry()
        }
      })

      assert {:ok, %{account_id: "acct_from_token"}} =
               OAuth.resolve(model, provider_options: [auth_mode: :oauth, oauth_file: path])
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
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      path = Path.join(tmp_dir, "oauth.json")

      write_oauth_file(path, %{
        "openai-codex" => %{
          "access" => "expired-access",
          "expires" => past_expiry()
        }
      })

      assert {:error, message} =
               OAuth.resolve(model, provider_options: [oauth_file: path])

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

  defp jwt_with_account_id(account_id) do
    header =
      %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "#{header}.#{payload}.sig"
  end
end
