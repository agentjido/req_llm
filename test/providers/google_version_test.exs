defmodule ReqLLM.Providers.GoogleVersionTest do
  @moduledoc """
  Tests for Google API version selection and validation.
  """

  use ExUnit.Case, async: true

  describe "API version validation" do
    test "rejects v1 with grounding enabled" do
      result =
        ReqLLM.generate_text(
          "google:gemini-2.0-flash",
          "test",
          provider_options: [
            google_api_version: "v1",
            google_grounding: %{enable: true}
          ]
        )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} = result
      assert error.parameter =~ "google_grounding requires google_api_version"
    end

    test "allows v1beta with grounding enabled" do
      opts = [
        provider_options: [
          google_api_version: "v1beta",
          google_grounding: %{enable: true}
        ]
      ]

      assert {:ok, request} =
               ReqLLM.Providers.Google.prepare_request(
                 :chat,
                 "google:gemini-2.0-flash",
                 "test",
                 opts
               )

      assert request.options[:base_url] == "https://generativelanguage.googleapis.com/v1beta"
    end

    test "defaults to v1beta without explicit version" do
      opts = [provider_options: []]

      assert {:ok, request} =
               ReqLLM.Providers.Google.prepare_request(
                 :chat,
                 "google:gemini-2.0-flash",
                 "test",
                 opts
               )

      assert request.options[:base_url] == "https://generativelanguage.googleapis.com/v1beta"
    end
  end
end
