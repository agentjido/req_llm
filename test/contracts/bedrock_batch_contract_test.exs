defmodule ReqLLM.BedrockBatchContractTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Batch, Context, Error, Response}
  alias ReqLLM.Batch.Job
  alias ReqLLM.Message.ContentPart

  @fixtures Path.expand("../support/fixtures/amazon_bedrock/batch", __DIR__)
  @arn "arn:aws:bedrock:us-west-2:123456789012:model-invocation-job/abc123def456"
  @model %{provider: :amazon_bedrock, id: "example.new-model-v1:0"}
  @input_uri "s3://batch-input/records.jsonl"
  @output_uri "s3://batch-output/results/"
  @role_arn "arn:aws:iam::123456789012:role/BedrockBatch"
  @profile_arn "arn:aws:bedrock:us-west-2:123456789012:application-inference-profile/example12345"
  @auth_opts [
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "example-secret",
    session_token: "example-session",
    req_http_options: [plug: {Req.Test, __MODULE__}]
  ]
  @job_opts [
    region: "us-west-2",
    job_name: "example-batch",
    output_uri: @output_uri,
    role_arn: @role_arn
  ]

  test "encodes contexts, retries a signed submission, and decodes results after resuming by ARN" do
    context = Context.new([Context.system("Reply with one word."), Context.user("Name a color.")])
    records = [{"example-0001", context}, {"example-0002", "Classify this:"}]

    assert {:ok, jsonl} = Batch.encode_jsonl(@model, records, max_tokens: 8, stop: "END")
    assert [first, second, ""] = jsonl |> IO.iodata_to_binary() |> String.split("\n")

    assert Jason.decode!(first) == %{
             "recordId" => "example-0001",
             "modelInput" => %{
               "system" => [%{"text" => "Reply with one word."}],
               "messages" => [%{"role" => "user", "content" => [%{"text" => "Name a color."}]}],
               "inferenceConfig" => %{"maxTokens" => 8, "stopSequences" => ["END"]}
             }
           }

    assert %{"recordId" => "example-0002"} = Jason.decode!(second)

    fixture = @fixtures |> Path.join("control_plane.json") |> File.read!() |> Jason.decode!()

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> capture_submission()
      |> Plug.Conn.put_status(503)
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Req.Test.json(fixture["retry"])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> capture_submission() |> Req.Test.json(fixture["submitted"])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert_signed(conn, "GET", "/model-invocation-job/abc123def456")
      Req.Test.json(conn, fixture["status"])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert_signed(conn, "POST", "/model-invocation-job/abc123def456/stop")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, %Job{provider: :amazon_bedrock, id: @arn, output: @output_uri} = submitted} =
             Batch.submit(
               @model,
               @input_uri,
               @job_opts ++ @auth_opts ++ [inference_profile_arn: @profile_arn]
             )

    assert_received {:submission, first_attempt}
    assert_received {:submission, second_attempt}
    assert first_attempt == second_attempt

    assert %{
             "clientRequestToken" => token,
             "jobName" => "example-batch",
             "roleArn" => @role_arn,
             "modelId" => @profile_arn,
             "modelInvocationType" => "Converse",
             "inputDataConfig" => %{"s3InputDataConfig" => %{"s3Uri" => @input_uri}},
             "outputDataConfig" => %{"s3OutputDataConfig" => %{"s3Uri" => @output_uri}}
           } = Jason.decode!(first_attempt)

    assert byte_size(token) > 0

    resumed = %Job{provider: submitted.provider, id: submitted.id}

    assert {:ok, %Job{status: "PartiallyCompleted", output: @output_uri}} =
             Batch.status(resumed, @auth_opts)

    assert :ok = Batch.cancel(resumed, @auth_opts)

    lines = @fixtures |> Path.join("results.jsonl.out") |> File.stream!()
    assert {:ok, results} = Batch.decode_jsonl(@model, lines)

    assert [
             {"example-0002", {:error, %Error.API.Request{provider_code: 400}}},
             {"example-0001", {:ok, response}}
           ] = Enum.to_list(results)

    assert Response.text(response) == "Blue"
    assert response.context.messages == context.messages ++ [response.message]
    assert response.model == @model.id
    assert response.finish_reason == :stop
    assert %{input_tokens: 12, output_tokens: 1} = response.usage
  end

  test "uses a persisted client token across calls and returns the service error" do
    Req.Test.expect(__MODULE__, 2, fn conn ->
      conn = capture_submission(conn)

      conn
      |> Plug.Conn.put_resp_header("x-amzn-errortype", "ValidationException")
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"message" => "Model is unavailable for batch inference in this region"})
    end)

    model = Map.put(@model, :provider_model_id, "example.wire-model-v1:0")
    opts = @job_opts ++ @auth_opts ++ [client_request_token: "persisted-request-token"]

    for _attempt <- 1..2 do
      assert {:error, %Error.API.Request{status: 400, provider_code: "ValidationException"}} =
               Batch.submit(model, @input_uri, opts)

      assert_received {:submission, body}

      assert %{
               "clientRequestToken" => "persisted-request-token",
               "modelId" => "example.wire-model-v1:0"
             } =
               Jason.decode!(body)
    end
  end

  test "preserves Expired and checks job ARN and request URI before network access" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert_signed(conn, "GET", "/model-invocation-job/abc123def456")

      Req.Test.json(conn, %{
        "status" => "Expired",
        "message" => "Job expired"
      })
    end)

    job = %Job{provider: :amazon_bedrock, id: @arn}

    assert {:ok, %Job{status: "Expired", message: "Job expired", output: nil}} =
             Batch.status(job, @auth_opts)

    assert {:error, %Error.Invalid.Parameter{}} =
             Batch.status(job, [region: "us-east-1"] ++ @auth_opts)

    assert {:error, %Error.Invalid.Parameter{}} =
             Batch.cancel(%{job | id: "../abc123def456"}, @auth_opts)

    assert {:error, %Error.Invalid.Parameter{}} =
             Batch.submit(@model, "https://example.com/input.jsonl", @job_opts ++ @auth_opts)
  end

  test "keeps capability discovery separate from installed adapter availability" do
    batch_capable = Map.put(@model, :capabilities, %{batch: %{supported: true}})
    unsupported = %{batch_capable | provider: :openai}

    assert Batch.supported?(batch_capable)
    refute Batch.supported?(@model)
    refute Batch.supported?(unsupported)

    assert {:error, %Error.Invalid.NotImplemented{}} =
             Batch.submit(unsupported, @input_uri, @job_opts ++ @auth_opts)
  end

  test "rejects duplicate record IDs and non-text contexts before staging" do
    assert {:error,
            %Error.Invalid.Parameter{parameter: "duplicate batch record ID \"example-0001\""}} =
             Batch.encode_jsonl(@model, [{"example-0001", "One"}, {"example-0001", "Two"}])

    image = ContentPart.image_url("https://example.com/image.png")
    context = Context.new([Context.user([ContentPart.text("Describe the image."), image])])

    assert {:error, %Error.Invalid.Parameter{}} =
             Batch.encode_jsonl(@model, [{"example-0001", context}])

    assert {:error, %Error.Invalid.Parameter{}} = Batch.encode_jsonl(@model, [])

    assert {:error, %Error.Invalid.Parameter{parameter: "batch record \"bad\": invalid prompt"}} =
             Batch.encode_jsonl(@model, [{"bad", 42}])
  end

  test "returns malformed row errors lazily and continues decoding" do
    lines = [
      "{invalid",
      ~s({"recordId":"bad-row","modelOutput":{}}),
      ~s({"recordId":"later","error":{"errorCode":429}})
    ]

    streamed = Stream.each(lines, &send(self(), {:decoded, &1}))

    assert {:ok, results} = Batch.decode_jsonl(@model, streamed)
    refute_received {:decoded, _line}

    assert [
             {nil,
              {:error, %Error.API.Response{reason: "Bedrock batch output line 1: invalid JSON"}}},
             {"bad-row", {:error, %Error.API.Response{}}},
             {"later", {:error, %Error.API.Request{provider_code: 429}}}
           ] = Enum.to_list(results)
  end

  defp capture_submission(conn) do
    assert_signed(conn, "POST", "/model-invocation-job")
    assert {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(self(), {:submission, body})
    conn
  end

  defp assert_signed(conn, method, path) do
    assert conn.method == method
    assert conn.request_path == path
    assert conn.host == "bedrock.us-west-2.amazonaws.com"
    assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")

    assert authorization =~
             ~r|^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/\d{8}/us-west-2/bedrock/aws4_request,|

    assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["example-session"]
  end
end
