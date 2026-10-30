defmodule Provider.OpenAI.OAuthTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.OAuth
  alias ReqLLM.Test.HTTPAdapter

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
                 oauth_http_options:
                   HTTPAdapter.options(
                     response_adapter(200, %{
                       "access_token" => access_token,
                       "refresh_token" => "fresh-refresh-token",
                       "expires_in" => 3600
                     })
                   )
               )

      assert is_integer(expires)
      assert expires > System.system_time(:millisecond)
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
