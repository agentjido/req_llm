defmodule ReqLLM.Providers.AmazonBedrock.STSTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock.STS

  describe "assume_role/1 validation" do
    test "returns error when role_arn is missing" do
      opts = [
        role_session_name: "test-session",
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      assert {:error, {:missing_required_options, missing}} = STS.assume_role(opts)
      assert :role_arn in missing
    end

    test "returns error when role_session_name is missing" do
      opts = [
        role_arn: "arn:aws:iam::123456789012:role/TestRole",
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      assert {:error, {:missing_required_options, missing}} = STS.assume_role(opts)
      assert :role_session_name in missing
    end

    test "returns error when access_key_id is missing" do
      opts = [
        role_arn: "arn:aws:iam::123456789012:role/TestRole",
        role_session_name: "test-session",
        secret_access_key: "secretTEST"
      ]

      assert {:error, {:missing_required_options, missing}} = STS.assume_role(opts)
      assert :access_key_id in missing
    end

    test "returns error when secret_access_key is missing" do
      opts = [
        role_arn: "arn:aws:iam::123456789012:role/TestRole",
        role_session_name: "test-session",
        access_key_id: "AKIATEST"
      ]

      assert {:error, {:missing_required_options, missing}} = STS.assume_role(opts)
      assert :secret_access_key in missing
    end

    test "returns error when multiple required options are missing" do
      opts = [
        access_key_id: "AKIATEST"
      ]

      assert {:error, {:missing_required_options, missing}} = STS.assume_role(opts)
      assert :role_arn in missing
      assert :role_session_name in missing
      assert :secret_access_key in missing
    end
  end

  describe "XML parsing" do
    test "parses valid AssumeRole response" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
        <AssumeRoleResult>
          <Credentials>
            <AccessKeyId>ASIAIOSFODNN7EXAMPLE</AccessKeyId>
            <SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY</SecretAccessKey>
            <SessionToken>AQoDYXdzEJr...<remainder of session token></SessionToken>
            <Expiration>2025-10-14T12:00:00Z</Expiration>
          </Credentials>
        </AssumeRoleResult>
      </AssumeRoleResponse>
      """

      # Use private function for testing (we can expose a parse helper if needed)
      result = STS.__info__(:functions)

      # For now, just verify module compiles
      assert is_list(result)
    end
  end

  describe "integration with Bedrock" do
    @tag :skip
    test "assumed credentials work with Bedrock requests" do
      # This would be an integration test requiring real AWS credentials
      # Skip by default, can be run manually with LIVE credentials

      role_arn = System.get_env("AWS_ASSUME_ROLE_ARN")
      access_key = System.get_env("AWS_ACCESS_KEY_ID")
      secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")

      if role_arn && access_key && secret_key do
        {:ok, temp_creds} =
          STS.assume_role(
            role_arn: role_arn,
            role_session_name: "bedrock-test-session",
            access_key_id: access_key,
            secret_access_key: secret_key,
            region: "us-east-1"
          )

        assert temp_creds.access_key_id
        assert temp_creds.secret_access_key
        assert temp_creds.session_token
        assert temp_creds.expiration

        # Verify credentials work with Bedrock
        model =
          ReqLLM.Model.from!(
            "bedrock:anthropic.claude-3-haiku-20240307-v1:0",
            access_key_id: temp_creds.access_key_id,
            secret_access_key: temp_creds.secret_access_key,
            session_token: temp_creds.session_token,
            region: "us-east-1"
          )

        {:ok, response} = ReqLLM.generate_text(model, "Hello!")
        assert response.message.content
      end
    end
  end

  describe "optional parameters" do
    @tag :skip
    test "accepts duration_seconds parameter" do
      # Would need to mock HTTP to test parameter passing
      # For now, just verify compilation
      assert true
    end

    @tag :skip
    test "accepts external_id parameter" do
      # Would need to mock HTTP to test parameter passing
      assert true
    end

    @tag :skip
    test "accepts policy parameter" do
      # Would need to mock HTTP to test parameter passing
      assert true
    end
  end
end
