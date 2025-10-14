defmodule ReqLLM.Providers.AmazonBedrock.STSIntegrationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock.STS

  @fixture_path "test/support/fixtures/aws_sts/assume_role.json"

  describe "AssumeRole with fixture" do
    test "parses credentials from recorded fixture" do
      # Load fixture
      fixture = File.read!(@fixture_path) |> Jason.decode!()
      xml_response = fixture["response"]["body"]

      # Parse the sanitized XML (should still work)
      assert {:ok, creds} = STS.parse_credentials(xml_response)

      # Verify structure
      assert creds.access_key_id == "ASIAREDACTEDREDACTED"
      assert creds.secret_access_key == "RedactedSecretAccessKey0123456789ABCDEF"
      assert String.starts_with?(creds.session_token, "RedactedSessionToken")
      assert %DateTime{} = creds.expiration
    end

    test "fixture contains no real credentials" do
      fixture_content = File.read!(@fixture_path)

      # Verify no real AWS credentials leaked
      refute String.contains?(fixture_content, "AKIA"),
             "Fixture should not contain real access keys"

      refute String.contains?(fixture_content, "ASIA") and
               not String.contains?(fixture_content, "ASIAREDACTED"),
             "Fixture should not contain real temporary keys"

      # Verify sanitized values are present
      assert String.contains?(fixture_content, "ASIAREDACTED")
      assert String.contains?(fixture_content, "RedactedSecretAccessKey")
      assert String.contains?(fixture_content, "RedactedSessionToken")
      assert String.contains?(fixture_content, "[REDACTED]")
    end

    test "fixture has expected structure" do
      fixture = File.read!(@fixture_path) |> Jason.decode!()

      # Request metadata
      assert fixture["request"]["action"] == "AssumeRole"
      assert fixture["request"]["access_key_id"] == "[REDACTED]"
      assert fixture["request"]["secret_access_key"] == "[REDACTED]"
      assert String.starts_with?(fixture["request"]["role_arn"], "arn:aws:iam::")

      # Response metadata
      assert fixture["response"]["status"] == 200
      assert is_binary(fixture["response"]["body"])
      assert String.starts_with?(fixture["response"]["body"], "<AssumeRoleResponse")

      # Capture timestamp
      assert is_binary(fixture["captured_at"])
      {:ok, _datetime, _} = DateTime.from_iso8601(fixture["captured_at"])
    end
  end
end
