defmodule ReqLLM.Providers.AmazonBedrock.AdditionalTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock}

  describe "provider_id" do
    test "returns :amazon_bedrock" do
      assert AmazonBedrock.provider_id() == :amazon_bedrock
    end
  end

  describe "default_base_url" do
    test "returns bedrock endpoint format with region placeholder" do
      url = AmazonBedrock.base_url()
      assert url =~ "bedrock-runtime"
      assert url =~ "amazonaws.com"
      assert url =~ "{region}"
    end
  end

  describe "response wrapping" do
    test "wraps map in Response struct" do
      data = %{"test" => "value"}
      result = AmazonBedrock.wrap_response(data)
      assert %AmazonBedrock.Response{payload: ^data} = result
    end

    test "doesn't double-wrap Response" do
      already = %AmazonBedrock.Response{payload: %{"test" => true}}
      result = AmazonBedrock.wrap_response(already)
      assert result == already
    end

    test "returns non-maps unchanged" do
      assert AmazonBedrock.wrap_response("test") == "test"
      assert AmazonBedrock.wrap_response(nil) == nil
      assert AmazonBedrock.wrap_response(123) == 123
    end
  end

  describe "model family detection" do
    test "handles anthropic models" do
      # These should all be detected as anthropic
      models = [
        "anthropic.claude-3-haiku-20240307-v1:0",
        "us.anthropic.claude-3-sonnet-20240229-v1:0",
        "eu.anthropic.claude-opus-4-20250514-v1:0"
      ]

      for model_id <- models do
        # We can't test private functions directly, but we can test
        # that anthropic models don't raise when building requests
        model = %LLMDB.Model{
          id: model_id,
          provider: :amazon_bedrock
        }

        context = Context.new([Context.user("test")])

        opts = [
          access_key_id: "AKIATEST",
          secret_access_key: "secretTEST",
          region: "us-east-1",
          use_converse: false
        ]

        # This should not raise for anthropic models
        assert {:ok, request} =
                 AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

        assert request.body =~ "anthropic_version"
      end
    end

    test "uses Converse API as fallback for models without dedicated formatters" do
      models_without_formatters = [
        "amazon.titan-text-express-v1",
        "cohere.command-text-v14",
        "ai21.jamba-1-5-large-v1:0"
      ]

      for model_id <- models_without_formatters do
        model = %LLMDB.Model{
          id: model_id,
          provider: :amazon_bedrock
        }

        context = Context.new([Context.user("test")])

        opts = [
          access_key_id: "AKIATEST",
          secret_access_key: "secretTEST"
        ]

        # Models without dedicated formatters should use Converse API
        assert {:ok, request} =
                 AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

        # Converse API uses /converse-stream endpoint
        assert request.path =~ "/converse-stream"
      end
    end
  end

  describe "AWS credential validation" do
    test "accepts valid credentials" do
      model = %LLMDB.Model{
        id: "anthropic.claude-3-haiku-20240307-v1:0",
        provider: :amazon_bedrock
      }

      context = Context.new([Context.user("test")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST"
      ]

      # Should not raise with valid creds
      assert {:ok, _} = AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)
    end
  end

  describe "request building" do
    test "builds finch request with correct headers" do
      model = %LLMDB.Model{
        id: "anthropic.claude-3-haiku-20240307-v1:0",
        provider: :amazon_bedrock
      }

      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-west-2"
      ]

      {:ok, request} = AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      assert request.scheme == :https
      assert request.port == 443
      assert request.method == "POST"
      assert request.host == "bedrock-runtime.us-west-2.amazonaws.com"

      assert request.path ==
               "/model/anthropic.claude-3-haiku-20240307-v1:0/invoke-with-response-stream"

      headers_map = Map.new(request.headers)
      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert headers_map["authorization"] =~ "AWS4-HMAC-SHA256"
    end

    test "includes session token when provided" do
      model = %LLMDB.Model{
        id: "anthropic.claude-3-haiku-20240307-v1:0",
        provider: :amazon_bedrock
      }

      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        session_token: "TOKEN123"
      ]

      {:ok, request} = AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      headers_map = Map.new(request.headers)
      assert headers_map["x-amz-security-token"] == "TOKEN123"
    end

    test "formats request body correctly" do
      model = %LLMDB.Model{
        id: "anthropic.claude-3-haiku-20240307-v1:0",
        provider: :amazon_bedrock
      }

      context =
        Context.new([
          Context.system("Be helpful"),
          Context.user("Hello")
        ])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        max_tokens: 500,
        temperature: 0.7
      ]

      {:ok, request} = AmazonBedrock.attach_stream(model, context, opts, __MODULE__.TestFinch)

      body = Jason.decode!(request.body)
      assert body["anthropic_version"] == "bedrock-2023-05-31"
      assert body["max_tokens"] == 500
      assert body["temperature"] == 0.7
      assert body["system"] == "Be helpful"
      assert [%{"role" => "user", "content" => _}] = body["messages"]
    end
  end

  describe "parse_stream_protocol" do
    test "parses valid AWS Event Stream message" do
      # Create a JSON payload that will be parsed
      payload = Jason.encode!(%{"test" => "data"})
      message = build_event_stream_message(payload)

      # Parser returns decoded JSON objects
      assert {:ok, [decoded], <<>>} = AmazonBedrock.parse_stream_protocol(message, <<>>)
      assert decoded == %{"test" => "data"}
    end

    test "handles incomplete data" do
      # Just a few bytes, not enough for a message
      partial = <<0, 0, 0, 50>>

      assert {:incomplete, ^partial} = AmazonBedrock.parse_stream_protocol(partial, <<>>)
    end

    test "accumulates across chunks" do
      payload = Jason.encode!(%{"complete" => true})
      message = build_event_stream_message(payload)

      # Split in half
      mid = div(byte_size(message), 2)
      part1 = binary_part(message, 0, mid)
      part2 = binary_part(message, mid, byte_size(message) - mid)

      # First part incomplete
      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(part1, <<>>)

      # Second part completes
      assert {:ok, [decoded], <<>>} = AmazonBedrock.parse_stream_protocol(part2, buffer)
      assert decoded == %{"complete" => true}
    end
  end

  # Build a valid AWS Event Stream message
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

# Minimal test finch module
defmodule ReqLLM.Providers.AmazonBedrock.AdditionalTest.TestFinch do
  @moduledoc false
end
