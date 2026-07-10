defmodule Provider.Anthropic.OAuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic.OAuth

  describe "refresh/2" do
    test "returns a local error when the refresh token is missing" do
      adapter = fn _request -> flunk("HTTP request should not be made") end

      assert {:error, "Anthropic OAuth credentials are missing a refresh token"} =
               OAuth.refresh(%{}, oauth_http_options: [adapter: adapter])
    end

    test "returns a local error when the refresh token is blank" do
      adapter = fn _request -> flunk("HTTP request should not be made") end

      assert {:error, "Anthropic OAuth credentials are missing a refresh token"} =
               OAuth.refresh(%{refresh: "   "}, oauth_http_options: [adapter: adapter])
    end

    test "returns refreshed credentials with an epoch-millisecond expiry" do
      before_refresh = System.system_time(:millisecond)

      assert {:ok,
              %{
                "type" => "oauth",
                "access" => "fresh-access-token",
                "refresh" => "fresh-refresh-token",
                "expires" => expires
              } = credentials} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(200, %{
                       "access_token" => "fresh-access-token",
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => 3600
                     })
                 ]
               )

      after_refresh = System.system_time(:millisecond)

      assert expires >= before_refresh + 3_600_000
      assert expires <= after_refresh + 3_600_000
      refute Map.has_key?(credentials, "accountId")
    end

    test "posts the refresh token grant as JSON to the Anthropic token endpoint" do
      adapter = fn request ->
        assert URI.to_string(request.url) == "https://platform.claude.com/v1/oauth/token"
        assert Req.Request.get_header(request, "content-type") == ["application/json"]

        assert Jason.decode!(request.body) == %{
                 "grant_type" => "refresh_token",
                 "client_id" => "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                 "refresh_token" => "refresh-token-123"
               }

        {request,
         %Req.Response{
           status: 200,
           body: %{
             "access_token" => "fresh-access-token",
             "refresh_token" => "fresh-refresh-token",
             "expires_in" => 3600
           }
         }}
      end

      assert {:ok, _credentials} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [adapter: adapter]
               )
    end

    test "returns an error when the refresh response is missing access_token" do
      assert {:error, "Anthropic OAuth refresh response did not include access_token"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [adapter: response_adapter(200, "not-json")]
               )
    end

    test "returns an error when the refresh response is missing refresh_token" do
      assert {:error, "Anthropic OAuth refresh response did not include refresh_token"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
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
      assert {:error, "Anthropic OAuth refresh response did not include expires_in"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(200, %{
                       "access_token" => "fresh-access-token",
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => "soon"
                     })
                 ]
               )
    end

    test "formats nested OAuth error messages from failed refresh responses" do
      assert {:error, "Anthropic OAuth refresh failed with status 401: refresh denied"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [
                   adapter:
                     response_adapter(401, %{
                       "error" => %{"message" => "refresh denied"}
                     })
                 ]
               )
    end

    test "formats string OAuth error messages from failed refresh responses" do
      assert {:error, "Anthropic OAuth refresh failed with status 401: refresh denied"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [
                   adapter: response_adapter(401, %{"error" => "refresh denied"})
                 ]
               )
    end

    test "formats top-level OAuth error messages from failed refresh responses" do
      assert {:error, "Anthropic OAuth refresh failed with status 400: refresh denied"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [
                   adapter: response_adapter(400, %{"message" => "refresh denied"})
                 ]
               )
    end

    test "falls back to a status-only error for unstructured failed refresh responses" do
      assert {:error, "Anthropic OAuth refresh failed with status 500"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [adapter: response_adapter(500, [:bad_response])]
               )
    end

    test "returns adapter exceptions as OAuth refresh errors" do
      assert {:error, "Anthropic OAuth refresh failed: boom"} =
               OAuth.refresh(%{refresh: "refresh-token-123"},
                 oauth_http_options: [adapter: error_adapter("boom")]
               )
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
end
