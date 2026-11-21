defmodule ReqLLM.Providers.AmazonBedrock.Batch do
  @moduledoc """
  Bedrock batch inference over the regional control plane, using text-only
  Converse records staged in S3 by the caller.
  """

  @behaviour ReqLLM.Batch.Adapter

  alias ReqLLM.Batch.Job
  alias ReqLLM.Error
  alias ReqLLM.Providers.AmazonBedrock.{AWSAuthAdapter, BatchJSONL}

  @job_path "/model-invocation-job"
  @job_arn ~r/\Aarn:aws(?:-[a-z0-9-]+)?:bedrock:([a-z0-9-]{1,20}):[0-9]{12}:model-invocation-job\/([a-z0-9]{12})\z/
  @region ~r/\A[a-z0-9-]{1,20}\z/
  @credential_keys [:access_key_id, :secret_access_key, :session_token]
  @request_options [
    access_key_id: [type: :string],
    secret_access_key: [type: :string],
    session_token: [type: :string],
    region: [type: :string],
    req_http_options: [type: :keyword_list, default: []]
  ]
  @submit_schema NimbleOptions.new!(
                   @request_options ++
                     [
                       job_name: [type: :string, required: true],
                       role_arn: [type: :string, required: true],
                       output_uri: [type: :string, required: true],
                       client_request_token: [type: :string],
                       inference_profile_arn: [type: :string]
                     ]
                 )
  @request_schema NimbleOptions.new!(@request_options)

  @impl true
  defdelegate encode_jsonl(model, records, opts), to: BatchJSONL

  @impl true
  defdelegate decode_jsonl(model, lines), to: BatchJSONL

  @doc """
  Submits a Converse job for an S3 input URI. Requires `:job_name`, `:role_arn`,
  and `:output_uri`. Use `:inference_profile_arn` to target an eligible profile.

  Provide `:region` and IAM credentials via the standard AWS environment
  variables or the `:region`, `:access_key_id`, `:secret_access_key`, and
  `:session_token` options. `:req_http_options` controls Req settings.

  Req retries transient submission failures with the same token. Supply and
  persist `:client_request_token` before submission to reuse it across calls.
  """
  @impl true
  def submit(model, input_uri, opts) do
    with {:ok, opts} <- validate_options(opts, @submit_schema),
         :ok <- validate_s3_uri(input_uri, :input_uri),
         :ok <- validate_s3_uri(opts[:output_uri], :output_uri),
         {:ok, body} <-
           request(
             opts[:region],
             opts,
             method: :post,
             path: @job_path,
             json: submission_body(model, input_uri, opts),
             retry: :transient
           ) do
      submitted_job(body, opts[:output_uri])
    end
  end

  @doc "Fetches the AWS status and output URI, routing to the region in the saved ARN."
  @impl true
  def status(%Job{id: arn} = job, opts) do
    with {:ok, opts} <- validate_options(opts, @request_schema),
         {:ok, region, path} <- job_route(arn, opts),
         {:ok, body} <- request(region, opts, method: :get, path: path) do
      case body do
        %{"status" => status} when is_binary(status) and status != "" ->
          {:ok,
           %{
             job
             | status: status,
               output: output_uri(body) || job.output,
               message: body["message"]
           }}

        _ ->
          {:error, response_error("missing status in Bedrock batch job", body)}
      end
    end
  end

  @doc "Sends a stop request to Bedrock for the job identified by the saved ARN."
  @impl true
  def cancel(%Job{id: arn}, opts) do
    with {:ok, opts} <- validate_options(opts, @request_schema),
         {:ok, region, path} <- job_route(arn, opts),
         {:ok, _body} <- request(region, opts, method: :post, path: path <> "/stop") do
      :ok
    end
  end

  defp submitted_job(body, output_uri) do
    with %{"jobArn" => arn} when is_binary(arn) <- body,
         true <- Regex.match?(@job_arn, arn) do
      {:ok, %Job{provider: :amazon_bedrock, id: arn, output: output_uri}}
    else
      _ -> {:error, response_error("missing or invalid jobArn in Bedrock batch submission", body)}
    end
  end

  defp output_uri(%{"outputDataConfig" => %{"s3OutputDataConfig" => %{"s3Uri" => uri}}})
       when is_binary(uri), do: uri

  defp output_uri(_body), do: nil

  defp submission_body(model, input_uri, opts) do
    %{
      "jobName" => opts[:job_name],
      "roleArn" => opts[:role_arn],
      "clientRequestToken" => opts[:client_request_token] || new_token(),
      "modelId" => opts[:inference_profile_arn] || model.provider_model_id || model.id,
      "modelInvocationType" => "Converse",
      "inputDataConfig" => %{"s3InputDataConfig" => %{"s3Uri" => input_uri}},
      "outputDataConfig" => %{"s3OutputDataConfig" => %{"s3Uri" => opts[:output_uri]}}
    }
  end

  defp new_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp job_route(arn, opts) when is_binary(arn) do
    case Regex.run(@job_arn, arn) do
      [_, region, id] ->
        if opts[:region] in [nil, region] do
          {:ok, region, @job_path <> "/" <> id}
        else
          {:error, invalid_parameter("region must match the Bedrock batch job ARN")}
        end

      nil ->
        {:error, invalid_parameter("expected a Bedrock batch job ARN")}
    end
  end

  defp job_route(_arn, _opts),
    do: {:error, invalid_parameter("expected a Bedrock batch job ARN")}

  defp request(region, opts, request_opts) do
    with {:ok, credentials} <- credentials(opts),
         {:ok, region} <- validate_region(region || credentials.region || "us-east-1") do
      {path, request_opts} = Keyword.pop!(request_opts, :path)

      suffix =
        if String.starts_with?(region, "cn-"), do: "amazonaws.com.cn", else: "amazonaws.com"

      url = "https://bedrock.#{region}.#{suffix}#{path}"

      opts[:req_http_options]
      |> Keyword.merge(request_opts)
      |> Keyword.merge(url: url, redirect: false, http_errors: :return)
      |> Req.new()
      |> AWSAuthAdapter.attach_request(
        credentials: credentials,
        service: "bedrock",
        region: region
      )
      |> Req.request()
      |> handle_response()
    end
  end

  defp credentials(opts) do
    :ok = AWSAuthAdapter.ensure_available!()

    case Keyword.take(opts, @credential_keys) do
      [] -> AWSAuthAdapter.from_env()
      explicit -> AWSAuthAdapter.from_map(explicit)
    end
    |> case do
      %{access_key_id: key, secret_access_key: secret} = credentials
      when is_binary(key) and key != "" and is_binary(secret) and secret != "" ->
        {:ok, credentials}

      _ ->
        {:error, invalid_parameter("Bedrock batch jobs require AWS IAM credentials")}
    end
  rescue
    error in RuntimeError -> {:error, invalid_parameter(String.trim(Exception.message(error)))}
  end

  defp handle_response({:ok, %{status: 200, body: body}}), do: {:ok, body}

  defp handle_response({:ok, response}) do
    {:error,
     Error.API.Request.exception(
       reason: "Bedrock batch request rejected",
       status: response.status,
       response_body: response.body,
       provider_code: response |> Req.Response.get_header("x-amzn-errortype") |> List.first()
     )}
  end

  defp handle_response({:error, error}) do
    {:error, Error.API.Request.exception(reason: "Bedrock batch request failed", cause: error)}
  end

  defp validate_options(opts, schema) do
    with true <- Keyword.keyword?(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, schema) do
      {:ok, opts}
    else
      false -> {:error, invalid_parameter("expected a keyword list of Bedrock batch options")}
      {:error, error} -> {:error, invalid_parameter(Exception.message(error))}
    end
  end

  defp validate_s3_uri("s3://" <> rest, _option)
       when rest != "" and binary_part(rest, 0, 1) != "/",
       do: :ok

  defp validate_s3_uri(_uri, option),
    do: {:error, invalid_parameter("#{option} must be an S3 URI")}

  defp validate_region(region) do
    if region =~ @region,
      do: {:ok, region},
      else: {:error, invalid_parameter("invalid AWS region")}
  end

  defp invalid_parameter(reason), do: Error.Invalid.Parameter.exception(parameter: reason)

  defp response_error(reason, body) do
    Error.API.Response.exception(reason: reason, status: 200, response_body: body)
  end
end
