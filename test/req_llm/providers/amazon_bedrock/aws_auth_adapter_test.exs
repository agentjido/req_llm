defmodule ReqLLM.Providers.AmazonBedrock.AWSAuthAdapterTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock.AWSAuthAdapter

  describe "credentials" do
    test "builds and recognizes AWSAuth credentials structs dynamically" do
      creds =
        AWSAuthAdapter.credentials_struct(
          access_key_id: "AKIDEXAMPLE",
          secret_access_key: "secret",
          region: "us-east-1"
        )

      assert AWSAuthAdapter.credentials?(creds)
      refute AWSAuthAdapter.credentials?(%{})
    end
  end

  describe "signing" do
    test "signs authorization headers through the adapter" do
      creds =
        AWSAuthAdapter.credentials_struct(
          access_key_id: "AKIDEXAMPLE",
          secret_access_key: "secret",
          region: "us-east-1"
        )

      headers =
        AWSAuthAdapter.sign_authorization_header(
          creds,
          "POST",
          "https://sts.us-east-1.amazonaws.com/",
          "sts",
          headers: %{"host" => "sts.us-east-1.amazonaws.com"},
          payload: ""
        )

      assert Enum.any?(headers, fn {key, _value} -> key == "authorization" end)
    end
  end
end
