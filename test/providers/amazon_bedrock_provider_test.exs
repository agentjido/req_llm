defmodule ReqLLM.Providers.AmazonBedrockProviderTest do
  @moduledoc """
  Provider-level tests for AmazonBedrock implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.AmazonBedrock

  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.AmazonBedrock

  setup do
    # Set up fake AWS credentials for testing
    System.put_env("AWS_ACCESS_KEY_ID", "AKIATESTKEY123")
    System.put_env("AWS_SECRET_ACCESS_KEY", "testSecretKey456")
    System.put_env("AWS_REGION", "us-east-1")
    :ok
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert AmazonBedrock.provider_id() == :amazon_bedrock
      assert is_binary(AmazonBedrock.base_url())
      assert AmazonBedrock.base_url() =~ "bedrock-runtime"
      assert AmazonBedrock.base_url() =~ "amazonaws.com"
    end

    test "provider schema separation from core options" do
      schema_keys = AmazonBedrock.provider_schema().schema |> Keyword.keys()
      core_keys = Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "supported options include AWS-specific keys" do
      supported = AmazonBedrock.supported_provider_options()

      # Should support AWS credential options (provider-specific)
      assert :api_key in supported
      assert :access_key_id in supported
      assert :secret_access_key in supported
      assert :session_token in supported
      assert :region in supported

      # Standard generation options should NOT be in provider-specific options
      refute :temperature in supported
      refute :max_tokens in supported

      # But they should be in the extended schema
      extended_schema = AmazonBedrock.provider_extended_generation_schema()
      extended_keys = Keyword.keys(extended_schema.schema)
      assert :temperature in extended_keys
      assert :max_tokens in extended_keys
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = AmazonBedrock.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request for Anthropic models" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        temperature: 0.7,
        max_tokens: 100,
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/model/anthropic.claude-3-haiku-20240307-v1:0/invoke"
      assert request.method == :post

      # Check that body contains proper Anthropic format
      body = Jason.decode!(request.body)
      assert body["anthropic_version"] == "bedrock-2023-05-31"
      assert body["max_tokens"] == 100
      assert body["temperature"] == 0.7
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      opts = [
        temperature: 0.5,
        max_tokens: 50,
        context: context_fixture(),
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      request = Req.new() |> AmazonBedrock.attach(model, opts)

      # Verify pipeline steps are configured
      request_steps = Keyword.keys(request.request_steps)
      assert :aws_sigv4 in request_steps
      assert :put_aws_sigv4 in request_steps

      response_steps = Keyword.keys(request.response_steps)
      assert :llm_decode_response in response_steps
    end

    test "attach with streaming option configures SSE" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      opts = [
        stream: true,
        context: context_fixture(),
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      request = Req.new() |> AmazonBedrock.attach(model, opts)

      # Should configure streaming endpoint
      assert request.url.path =~ "invoke-with-response-stream"
    end

    test "uses Converse API as fallback for models without dedicated formatters" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:cohere.command-text-v14")
      context = context_fixture()

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      # Models without dedicated formatters should use Converse API
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # Converse API uses /converse endpoint
      assert request.url.path =~ "/converse"
    end

    test "error handling for missing credentials" do
      # Clear environment variables
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")
      System.delete_env("AWS_BEARER_TOKEN_BEDROCK")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()
      opts = []

      assert_raise ArgumentError, ~r/AWS credentials required/, fn ->
        AmazonBedrock.prepare_request(:chat, model, context, opts)
      end
    end

    test "API key authentication via environment variable" do
      System.put_env("AWS_BEARER_TOKEN_BEDROCK", "test-api-key-123")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [region: "us-east-1"]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # Should create valid request with Bearer token
      assert %Req.Request{} = request
      assert request.url.host == "bedrock-runtime.us-east-1.amazonaws.com"

      # Check Authorization header is set to Bearer token
      headers = Req.Request.get_header(request, "authorization")
      assert headers == ["Bearer test-api-key-123"]
    end

    test "API key authentication via provider options" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        api_key: "test-api-key-456",
        region: "us-west-2"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # Should create valid request with Bearer token
      assert %Req.Request{} = request
      assert request.url.host == "bedrock-runtime.us-west-2.amazonaws.com"

      # Check Authorization header is set to Bearer token
      headers = Req.Request.get_header(request, "authorization")
      assert headers == ["Bearer test-api-key-456"]
    end

    test "API key takes precedence over IAM credentials" do
      # Set both IAM and API key
      System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secretTEST")

      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        api_key: "test-api-key-789",
        region: "us-east-1"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      # Should use Bearer token, not AWS SigV4
      headers = Req.Request.get_header(request, "authorization")
      assert headers == ["Bearer test-api-key-789"]
    end

    test "uses region from options" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "eu-west-1"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
    end

    test "includes session token when provided via streaming" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        session_token: "TOKEN123"
      ]

      # Session tokens are added as headers in streaming requests
      {:ok, finch_request} =
        AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      headers_map = Map.new(finch_request.headers)
      # AWS session tokens are passed via x-amz-security-token header
      # The test in additional_test.exs verifies this correctly
      assert headers_map["x-amz-security-token"] == "TOKEN123"
    end
  end

  describe "streaming support" do
    test "attach_stream builds proper Finch request" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-west-2"
      ]

      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      assert finch_request.scheme == :https
      assert finch_request.host == "bedrock-runtime.us-west-2.amazonaws.com"
      assert finch_request.path =~ "invoke-with-response-stream"
      assert finch_request.method == "POST"

      headers_map = Map.new(finch_request.headers)
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert headers_map["content-type"] == "application/json"
      assert headers_map["authorization"] =~ "AWS4-HMAC-SHA256"
    end

    test "attach_stream with API key authentication" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = context_fixture()

      opts = [
        api_key: "test-api-key-streaming-123",
        region: "us-west-2"
      ]

      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      assert finch_request.scheme == :https
      assert finch_request.host == "bedrock-runtime.us-west-2.amazonaws.com"
      assert finch_request.path =~ "invoke-with-response-stream"
      assert finch_request.method == "POST"

      headers_map = Map.new(finch_request.headers)
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert headers_map["content-type"] == "application/json"
      assert headers_map["authorization"] == "Bearer test-api-key-streaming-123"
    end

    test "parse_stream_protocol handles AWS Event Stream" do
      # Build a valid AWS Event Stream message
      payload = Jason.encode!(%{"test" => "data"})
      message = build_event_stream_message(payload)

      # The parser returns decoded JSON objects
      assert {:ok, [decoded], <<>>} = AmazonBedrock.parse_stream_protocol(message, <<>>)
      assert decoded == %{"test" => "data"}
    end

    test "parse_stream_protocol handles incomplete messages" do
      partial = <<0, 0, 0, 100, 0, 0>>
      assert {:incomplete, ^partial} = AmazonBedrock.parse_stream_protocol(partial, <<>>)
    end

    test "parse_stream_protocol accumulates across chunks" do
      payload = Jason.encode!(%{"complete" => true})
      message = build_event_stream_message(payload)

      # Split message in half
      mid = div(byte_size(message), 2)
      part1 = binary_part(message, 0, mid)
      part2 = binary_part(message, mid, byte_size(message) - mid)

      # First part should be incomplete
      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(part1, <<>>)

      # Second part should complete
      assert {:ok, [decoded], <<>>} = AmazonBedrock.parse_stream_protocol(part2, buffer)
      assert decoded == %{"complete" => true}
    end
  end

  describe "response handling" do
    test "extract_usage delegates to formatter" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      body = %{
        "usage" => %{
          "input_tokens" => 42,
          "output_tokens" => 100
        }
      }

      assert {:ok, usage} = AmazonBedrock.extract_usage(body, model)
      assert usage["input_tokens"] == 42
      assert usage["output_tokens"] == 100
    end

    # extract_content is not a public function in the provider
    # Content extraction is handled internally by the formatter

    test "wrap_response handles Response struct" do
      response = %AmazonBedrock.Response{payload: %{"data" => "test"}}
      assert AmazonBedrock.wrap_response(response) == response
    end

    test "wrap_response wraps maps" do
      data = %{"test" => "value"}
      wrapped = AmazonBedrock.wrap_response(data)
      assert %AmazonBedrock.Response{payload: ^data} = wrapped
    end

    # decode_response is a step function that expects {req, resp} tuples
    # It's used internally by the request pipeline, not called directly
  end

  # Helper to build a valid AWS Event Stream message for testing
  defp build_event_stream_message(payload) when is_binary(payload) do
    headers = <<>>
    headers_length = 0
    payload_length = byte_size(payload)
    total_length = 16 + headers_length + payload_length

    prelude = <<total_length::32-big, headers_length::32-big>>
    prelude_crc = :erlang.crc32(prelude)

    message_without_crc = <<
      prelude::binary,
      prelude_crc::32,
      headers::binary,
      payload::binary
    >>

    message_crc = :erlang.crc32(message_without_crc)

    <<
      total_length::32-big,
      headers_length::32-big,
      prelude_crc::32,
      headers::binary,
      payload::binary,
      message_crc::32
    >>
  end
end

# Test double for Finch
defmodule ReqLLM.Providers.AmazonBedrockProviderTest.TestFinch do
  @moduledoc false
end
