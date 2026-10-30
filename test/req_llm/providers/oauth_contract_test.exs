defmodule ReqLLM.Providers.OAuthContractTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.HTTPAdapter

  @contracts [
    {ReqLLM.Providers.OpenAI.OAuth, "OpenAI", %{"refresh" => "refresh-token-123"}},
    {ReqLLM.Providers.Anthropic.OAuth, "Anthropic", %{refresh: "refresh-token-123"}}
  ]

  for {oauth, label, credentials} <- @contracts do
    @oauth oauth
    @label label
    @credentials credentials

    test "#{label} requires access_token in a successful refresh response" do
      assert {:error, "#{@label} OAuth refresh response did not include access_token"} =
               @oauth.refresh(@credentials,
                 oauth_http_options: HTTPAdapter.options(response_adapter(200, "not-json"))
               )
    end

    test "#{label} requires refresh_token in a successful refresh response" do
      body = %{"access_token" => "fresh-access-token", "expires_in" => 3600}

      assert {:error, "#{@label} OAuth refresh response did not include refresh_token"} =
               @oauth.refresh(@credentials,
                 oauth_http_options: HTTPAdapter.options(response_adapter(200, body))
               )
    end

    test "#{label} requires a valid expires_in in a successful refresh response" do
      body = %{
        "access_token" => "fresh-access-token",
        "refresh_token" => "fresh-refresh-token",
        "expires_in" => "soon"
      }

      assert {:error, "#{@label} OAuth refresh response did not include expires_in"} =
               @oauth.refresh(@credentials,
                 oauth_http_options: HTTPAdapter.options(response_adapter(200, body))
               )
    end

    test "#{label} formats failed refresh responses" do
      cases = [
        {401, %{"error" => %{"message" => "refresh denied"}}, "refresh denied"},
        {401, %{"error" => "refresh denied"}, "refresh denied"},
        {400, %{"message" => "refresh denied"}, "refresh denied"},
        {500, [:bad_response], nil}
      ]

      for {status, body, detail} <- cases do
        expected = "#{@label} OAuth refresh failed with status #{status}"
        expected = if detail, do: expected <> ": " <> detail, else: expected

        assert {:error, ^expected} =
                 @oauth.refresh(@credentials,
                   oauth_http_options: HTTPAdapter.options(response_adapter(status, body))
                 )
      end
    end

    test "#{label} converts adapter exceptions into refresh errors" do
      assert {:error, "#{@label} OAuth refresh failed: boom"} =
               @oauth.refresh(@credentials,
                 oauth_http_options: HTTPAdapter.options(error_adapter("boom"))
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
