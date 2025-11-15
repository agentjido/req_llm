defmodule ReqLLM.Providers.AmazonBedrock.STS do
  @moduledoc """
  AWS Security Token Service (STS) integration for AssumeRole.

  Provides temporary credentials via AssumeRole without requiring ex_aws.
  Uses built-in :xmerl for XML parsing and existing ex_aws_auth for signing.

  ## Usage

      # AssumeRole with base credentials
      {:ok, temp_creds} = STS.assume_role(
        role_arn: "arn:aws:iam::123456789012:role/MyRole",
        role_session_name: "my-session",
        access_key_id: "AKIA...",
        secret_access_key: "...",
        region: "us-east-1"
      )

      # Use temporary credentials with Bedrock
      model = ReqLLM.model("bedrock:anthropic.claude-3-sonnet-20240229-v1:0",
        access_key_id: temp_creds.access_key_id,
        secret_access_key: temp_creds.secret_access_key,
        session_token: temp_creds.session_token,
        region: "us-east-1"
      )
  """

  @doc """
  Assume an AWS IAM role and get temporary credentials.

  ## Options

    * `:role_arn` (required) - ARN of the role to assume
    * `:role_session_name` (required) - Name for the role session
    * `:access_key_id` (required) - AWS access key ID of the caller
    * `:secret_access_key` (required) - AWS secret access key of the caller
    * `:region` - AWS region (default: "us-east-1")
    * `:duration_seconds` - Session duration in seconds (default: 3600, max: 43200)
    * `:external_id` - External ID for role assumption
    * `:policy` - IAM policy to further restrict permissions (JSON string)

  ## Returns

    * `{:ok, credentials}` - Map with access_key_id, secret_access_key, session_token, expiration
    * `{:error, reason}` - Error details

  ## Examples

      {:ok, creds} = STS.assume_role(
        role_arn: "arn:aws:iam::123456789012:role/MyRole",
        role_session_name: "bedrock-session",
        access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
      )

      # creds = %{
      #   access_key_id: "ASIAXXX...",
      #   secret_access_key: "xxx...",
      #   session_token: "xxx...",
      #   expiration: ~U[2025-10-14 12:00:00Z]
      # }
  """
  def assume_role(opts) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, response_body} <- call_sts(validated_opts) do
      parse_credentials(response_body)
    end
  end

  # Validate required options
  defp validate_options(opts) do
    required = [:role_arn, :role_session_name, :access_key_id, :secret_access_key]

    missing =
      Enum.filter(required, fn key ->
        is_nil(Keyword.get(opts, key))
      end)

    if missing == [] do
      {:ok, opts}
    else
      {:error, {:missing_required_options, missing}}
    end
  end

  # Call AWS STS AssumeRole API
  defp call_sts(opts) do
    region = Keyword.get(opts, :region, "us-east-1")
    endpoint = "https://sts.#{region}.amazonaws.com/"

    # Build form parameters for AssumeRole
    params = build_params(opts)
    body = URI.encode_query(params)

    # Build request
    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Host", "sts.#{region}.amazonaws.com"}
    ]

    # Sign request with AWS SigV4
    signed_headers =
      sign_sts_request(
        opts[:access_key_id],
        opts[:secret_access_key],
        region,
        endpoint,
        headers,
        body
      )

    # Make HTTP request (disable auto-decode to get raw XML)
    case Req.post(endpoint, headers: signed_headers, body: body, raw: true) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:sts_api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # Build STS AssumeRole query parameters
  defp build_params(opts) do
    base_params = [
      {"Action", "AssumeRole"},
      {"Version", "2011-06-15"},
      {"RoleArn", opts[:role_arn]},
      {"RoleSessionName", opts[:role_session_name]}
    ]

    # Add optional parameters
    base_params
    |> maybe_add_param("DurationSeconds", opts[:duration_seconds])
    |> maybe_add_param("ExternalId", opts[:external_id])
    |> maybe_add_param("Policy", opts[:policy])
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, to_string(value)}]

  # Sign STS request using ex_aws_auth
  defp sign_sts_request(access_key_id, secret_access_key, region, url, headers, body) do
    case Code.ensure_loaded(AWSAuth) do
      {:module, _} ->
        :ok

      {:error, _} ->
        raise """
        AWS STS AssumeRole requires the ex_aws_auth dependency.
        Please add {:ex_aws_auth, "~> 1.3", optional: true} to your mix.exs dependencies.
        """
    end

    # Create credentials struct
    creds = %AWSAuth.Credentials{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region
    }

    # Convert headers to map
    headers_map = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)

    # Sign using new credential-based API
    AWSAuth.sign_authorization_header(
      creds,
      "POST",
      url,
      "sts",
      headers: headers_map,
      payload: body
    )
  end

  @doc """
  Parse AWS STS AssumeRole XML response into credentials.

  Exposed for testing purposes.

  ## Examples

      xml = "<AssumeRoleResponse>...</AssumeRoleResponse>"
      {:ok, creds} = STS.parse_credentials(xml)
  """
  def parse_credentials(xml_body) when is_binary(xml_body) do
    # Parse XML
    {doc, _} = :xmerl_scan.string(String.to_charlist(xml_body))

    # Extract credential fields using XPath
    access_key_id = extract_text(doc, ~c"//AccessKeyId")
    secret_access_key = extract_text(doc, ~c"//SecretAccessKey")
    session_token = extract_text(doc, ~c"//SessionToken")
    expiration = extract_text(doc, ~c"//Expiration")

    if access_key_id && secret_access_key && session_token do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token,
         expiration: parse_timestamp(expiration)
       }}
    else
      {:error, {:parse_error, "Missing credential fields in response"}}
    end
  rescue
    e -> {:error, {:xml_parse_error, e}}
  end

  # Extract text content from XML element using XPath
  defp extract_text(doc, xpath) do
    case :xmerl_xpath.string(xpath, doc) do
      [element | _] ->
        case :xmerl_xpath.string(~c"text()", element) do
          [{:xmlText, _, _, _, text, _} | _] ->
            List.to_string(text)

          [] ->
            nil
        end

      [] ->
        nil
    end
  end

  # Parse ISO8601 timestamp
  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _} -> datetime
      {:error, _} -> nil
    end
  end
end
