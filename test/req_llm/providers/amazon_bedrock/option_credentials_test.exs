defmodule ReqLLM.Providers.AmazonBedrock.OptionCredentialsTest do
  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Providers.AmazonBedrock}

  @env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION AWS_BEARER_TOKEN_BEDROCK)

  setup do
    original = Map.new(@env, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(original, &restore_env/1) end)

    System.put_env("AWS_ACCESS_KEY_ID", "AKIAENV")
    System.put_env("AWS_SECRET_ACCESS_KEY", "envSecret")
    System.put_env("AWS_REGION", "us-east-1")
    System.delete_env("AWS_DEFAULT_REGION")
    System.delete_env("AWS_SESSION_TOKEN")
    System.delete_env("AWS_BEARER_TOKEN_BEDROCK")

    {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

    nested_iam = [
      access_key_id: "AKIANESTED",
      secret_access_key: "nestedSecret",
      session_token: "nested-session-token"
    ]

    {:ok, model: model, context: Context.new([Context.user("Hello")]), nested_iam: nested_iam}
  end

  test "region option wins over AWS_REGION with environment credentials", %{
    model: model,
    context: context
  } do
    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, region: "eu-west-1")
    authorization = authorization(sign(request))

    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert authorization =~ "AKIAENV/"
    assert authorization =~ "/eu-west-1/bedrock/aws4_request"
  end

  test "provider_options region wins over AWS_REGION when streaming", %{
    model: model,
    context: context
  } do
    opts = [provider_options: [region: "eu-west-1"]]

    {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
    headers = Map.new(finch_request.headers)

    assert finch_request.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert headers["authorization"] =~ "AKIAENV/"
    assert headers["authorization"] =~ "/eu-west-1/bedrock/aws4_request"
  end

  test "uses credentials given in provider_options", %{
    model: model,
    context: context,
    nested_iam: nested_iam
  } do
    {:ok, api_key_request} =
      AmazonBedrock.prepare_request(:chat, model, context,
        provider_options: [api_key: "nested-api-key"]
      )

    assert Req.Request.get_header(api_key_request, "authorization") == ["Bearer nested-api-key"]

    {:ok, iam_request} =
      AmazonBedrock.prepare_request(:chat, model, context, provider_options: nested_iam)

    signed = sign(iam_request)

    assert authorization(signed) =~ "AWS4-HMAC-SHA256 Credential=AKIANESTED/"
    assert Req.Request.get_header(signed, "x-amz-security-token") == ["nested-session-token"]
  end

  test "uses credentials given in provider_options when streaming", %{
    model: model,
    context: context,
    nested_iam: nested_iam
  } do
    {:ok, api_key_request} =
      AmazonBedrock.attach_stream(
        model,
        context,
        [provider_options: [api_key: "nested-api-key"]],
        ReqLLM.Finch
      )

    assert Map.new(api_key_request.headers)["authorization"] == "Bearer nested-api-key"

    {:ok, iam_request} =
      AmazonBedrock.attach_stream(model, context, [provider_options: nested_iam], ReqLLM.Finch)

    headers = Map.new(iam_request.headers)

    assert headers["authorization"] =~ "AWS4-HMAC-SHA256 Credential=AKIANESTED/"
    assert headers["x-amz-security-token"] == "nested-session-token"
  end

  test "reads credentials from a string-keyed provider_options map", %{
    model: model,
    context: context
  } do
    opts = [provider_options: %{"api_key" => "map-api-key", "region" => "eu-west-1"}]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert Req.Request.get_header(request, "authorization") == ["Bearer map-api-key"]
  end

  test "reads credentials from a namespaced provider_options map", %{
    model: model,
    context: context
  } do
    opts = [
      provider_options: %{
        "amazon_bedrock" => %{"api_key" => "namespaced-api-key", "region" => "eu-west-1"}
      }
    ]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
    {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert Req.Request.get_header(request, "authorization") == ["Bearer namespaced-api-key"]
    assert finch_request.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert Map.new(finch_request.headers)["authorization"] == "Bearer namespaced-api-key"
  end

  test "preserves environment region fallback and session tokens", %{
    model: model,
    context: context
  } do
    System.put_env("AWS_SESSION_TOKEN", "env-session-token")

    for {aws_region, default_region, expected_region} <- [
          {"eu-central-1", "eu-west-1", "eu-central-1"},
          {nil, "eu-west-1", "eu-west-1"},
          {nil, nil, "us-east-1"}
        ] do
      restore_env({"AWS_REGION", aws_region})
      restore_env({"AWS_DEFAULT_REGION", default_region})

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, [])
      {:ok, stream} = AmazonBedrock.attach_stream(model, context, [], ReqLLM.Finch)
      signed = sign(request)
      headers = Map.new(stream.headers)

      assert request.url.host == "bedrock-runtime.#{expected_region}.amazonaws.com"
      assert stream.host == request.url.host
      assert authorization(signed) =~ "/#{expected_region}/bedrock/aws4_request"
      assert headers["authorization"] =~ "/#{expected_region}/bedrock/aws4_request"
      assert Req.Request.get_header(signed, "x-amz-security-token") == ["env-session-token"]
      assert headers["x-amz-security-token"] == "env-session-token"
    end
  end

  test "explicit IAM credentials win over an environment bearer token", %{
    model: model,
    context: context,
    nested_iam: nested_iam
  } do
    System.put_env("AWS_BEARER_TOKEN_BEDROCK", "env-api-key")
    opts = [provider_options: [amazon_bedrock: Keyword.put(nested_iam, :region, "eu-west-1")]]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
    {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
    credential = "Credential=AKIANESTED/"

    assert authorization(sign(request)) =~ credential
    assert Map.new(stream.headers)["authorization"] =~ credential
    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert stream.host == request.url.host
  end

  test "top-level IAM credentials and region win over nested values", %{
    model: model,
    context: context,
    nested_iam: nested_iam
  } do
    opts = [
      access_key_id: "AKIATOPLEVEL",
      secret_access_key: "topLevelSecret",
      session_token: "top-level-session-token",
      region: "eu-central-1",
      provider_options: Keyword.put(nested_iam, :region, "eu-west-1")
    ]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
    {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
    signed = sign(request)
    headers = Map.new(stream.headers)

    assert request.url.host == "bedrock-runtime.eu-central-1.amazonaws.com"
    assert stream.host == request.url.host
    assert authorization(signed) =~ "Credential=AKIATOPLEVEL/"
    assert headers["authorization"] =~ "Credential=AKIATOPLEVEL/"
    assert Req.Request.get_header(signed, "x-amz-security-token") == ["top-level-session-token"]
    assert headers["x-amz-security-token"] == "top-level-session-token"
  end

  test "top-level API key wins over nested credentials", %{
    model: model,
    context: context,
    nested_iam: nested_iam
  } do
    opts = [
      api_key: "top-level-api-key",
      provider_options: Keyword.put(nested_iam, :api_key, "nested-api-key")
    ]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
    {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

    assert Req.Request.get_header(request, "authorization") == ["Bearer top-level-api-key"]
    assert Map.new(stream.headers)["authorization"] == "Bearer top-level-api-key"
  end

  test "region option wins with an environment bearer token", %{model: model, context: context} do
    System.put_env("AWS_BEARER_TOKEN_BEDROCK", "env-api-key")
    opts = [provider_options: [region: "eu-west-1"]]

    {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
    {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert stream.host == request.url.host
    assert Req.Request.get_header(request, "authorization") == ["Bearer env-api-key"]
    assert Map.new(stream.headers)["authorization"] == "Bearer env-api-key"
  end

  test "embedding requests use nested credentials and explicit regions", %{nested_iam: nested_iam} do
    model = ReqLLM.model!("amazon_bedrock:cohere.embed-english-v3")

    for credentials <- [[], nested_iam] do
      opts = [provider_options: [amazon_bedrock: Keyword.put(credentials, :region, "eu-west-1")]]

      {:ok, request} = AmazonBedrock.prepare_request(:embedding, model, "Hello", opts)
      signed = sign(request)
      access_key = credentials[:access_key_id] || "AKIAENV"

      assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
      assert authorization(signed) =~ "Credential=#{access_key}/"
      assert authorization(signed) =~ "/eu-west-1/bedrock/aws4_request"
      assert Jason.decode!(request.body)["texts"] == ["Hello"]
    end

    {:ok, request} =
      AmazonBedrock.prepare_request(:embedding, model, "Hello",
        provider_options: %{"api_key" => "embedding-api-key", "region" => "eu-west-1"}
      )

    assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    assert Req.Request.get_header(request, "authorization") == ["Bearer embedding-api-key"]
  end

  test "a region option does not bypass missing credential errors", %{
    model: model,
    context: context
  } do
    System.delete_env("AWS_ACCESS_KEY_ID")
    System.delete_env("AWS_SECRET_ACCESS_KEY")
    opts = [provider_options: [region: "eu-west-1"]]

    assert_raise ArgumentError, ~r/AWS credentials required/, fn ->
      AmazonBedrock.prepare_request(:chat, model, context, opts)
    end

    assert {:error, {:bedrock_stream_build_failed, %ArgumentError{message: message}}} =
             AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

    assert message =~ "AWS credentials required"
  end

  defp sign(%Req.Request{} = request) do
    {:aws_sigv4, sign} = List.keyfind(request.request_steps, :aws_sigv4, 0)
    sign.(request)
  end

  defp authorization(%Req.Request{} = request) do
    [authorization] = Req.Request.get_header(request, "authorization")
    authorization
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)
end
