defmodule Provider.OpenAI.OAuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.OAuth

  describe "refresh/2" do
    test "returns refreshed credentials and derives account id from the access token" do
      access_token = jwt_with_account_id("acct_123")

      assert {:ok,
              %{
                "type" => "oauth",
                "access" => ^access_token,
                "refresh" => "fresh-refresh-token",
                "expires" => expires,
                "accountId" => "acct_123"
              }} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(200, %{
                       "access_token" => access_token,
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => 3600
                     })
                 ]
               )

      assert is_integer(expires)
      assert expires > System.system_time(:millisecond)
    end

    test "returns an error when the refresh response is missing access_token" do
      assert {:error, "OpenAI OAuth refresh response did not include access_token"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [adapter: response_adapter(200, "not-json")]
               )
    end

    test "returns an error when the refresh response is missing refresh_token" do
      assert {:error, "OpenAI OAuth refresh response did not include refresh_token"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(200, %{
                       "access_token" => "fresh-access-token",
                       "expires_in" => 3600
                     })
                 ]
               )
    end

    test "returns an error when expires_in is invalid" do
      assert {:error, "OpenAI OAuth refresh response did not include expires_in"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(200, %{
                       "access_token" => 123,
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => "soon"
                     })
                 ]
               )
    end

    test "formats nested OAuth error messages from failed refresh responses" do
      assert {:error, "OpenAI OAuth refresh failed with status 401: refresh denied"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(401, %{
                       "error" => %{"message" => "refresh denied"}
                     })
                 ]
               )
    end

    test "formats string OAuth error messages from failed refresh responses" do
      assert {:error, "OpenAI OAuth refresh failed with status 401: refresh denied"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter: response_adapter(401, %{"error" => "refresh denied"})
                 ]
               )
    end

    test "formats top-level OAuth error messages from failed refresh responses" do
      assert {:error, "OpenAI OAuth refresh failed with status 400: refresh denied"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [
                   adapter: response_adapter(400, %{"message" => "refresh denied"})
                 ]
               )
    end

    test "falls back to a status-only error for unstructured failed refresh responses" do
      assert {:error, "OpenAI OAuth refresh failed with status 500"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [adapter: response_adapter(500, [:bad_response])]
               )
    end

    test "returns adapter exceptions as OAuth refresh errors" do
      assert {:error, "OpenAI OAuth refresh failed: boom"} =
               OAuth.refresh(%{"refresh" => "refresh-token-123"},
                 oauth_http_options: [adapter: error_adapter("boom")]
               )
    end
  end

  describe "account_id_from_token/1" do
    test "returns nil for malformed or non-binary tokens" do
      assert OAuth.account_id_from_token("not-a-jwt") == nil
      assert OAuth.account_id_from_token("a.invalid-payload.sig") == nil
      assert OAuth.account_id_from_token(123) == nil
    end
  end

  defp response_adapter(status, body) do
    fn request ->
      {request, %Req.Response{status: status, body: body}}
    end
  end

  defp error_adapter(message) do
    fn request ->
      {request, RuntimeError.exception(message)}
    end
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
