defmodule Provider.Anthropic.OAuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic.OAuth
  alias ReqLLM.Test.HTTPAdapter

  describe "refresh/2" do
    test "returns a local error when the refresh token is missing" do
      adapter = fn _request -> flunk("HTTP request should not be made") end

      assert {:error, "Anthropic OAuth credentials are missing a refresh token"} =
               OAuth.refresh(%{}, oauth_http_options: HTTPAdapter.options(adapter))
    end

    test "returns a local error when the refresh token is blank" do
      adapter = fn _request -> flunk("HTTP request should not be made") end

      assert {:error, "Anthropic OAuth credentials are missing a refresh token"} =
               OAuth.refresh(%{refresh: "   "}, oauth_http_options: HTTPAdapter.options(adapter))
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
                 oauth_http_options:
                   HTTPAdapter.options(
                     response_adapter(200, %{
                       "access_token" => "fresh-access-token",
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => 3600
                     })
                   )
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
                 oauth_http_options: HTTPAdapter.options(adapter)
               )
    end
  end

  defp response_adapter(status, body) do
    fn request ->
      {request, %Req.Response{status: status, body: body}}
    end
  end
end
