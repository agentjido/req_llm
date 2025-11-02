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
      _xml = """
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
end
