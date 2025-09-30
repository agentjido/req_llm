defmodule ReqLLM.Providers.AmazonBedrockTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Model, Context, Providers.AmazonBedrock}

  describe "provider basics" do
    test "provider_id returns :amazon_bedrock" do
      assert AmazonBedrock.provider_id() == :amazon_bedrock
    end

    test "default_base_url returns Bedrock endpoint format" do
      url = AmazonBedrock.default_base_url()
      assert url =~ "bedrock-runtime"
      assert url =~ "amazonaws.com"
    end
  end

  describe "parse_stream_protocol/2" do
    test "parses AWS Event Stream binary data" do
      # Create a simple AWS Event Stream message
      payload = Jason.encode!(%{"type" => "chunk", "data" => "test"})
      binary = build_aws_event_stream_message(payload)

      assert {:ok, events, rest} = AmazonBedrock.parse_stream_protocol(binary, <<>>)
      refute Enum.empty?(events)
      assert rest == <<>>
    end

    test "handles incomplete data" do
      # Incomplete prelude
      partial = <<0, 0, 0, 100>>

      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(partial, <<>>)
      assert buffer == partial
    end

    test "accumulates with buffer" do
      # Split a message across two chunks
      payload = Jason.encode!(%{"test" => "data"})
      full_message = build_aws_event_stream_message(payload)

      split = div(byte_size(full_message), 2)
      part1 = binary_part(full_message, 0, split)
      part2 = binary_part(full_message, split, byte_size(full_message) - split)

      # First chunk should be incomplete
      assert {:incomplete, buffer} = AmazonBedrock.parse_stream_protocol(part1, <<>>)

      # Second chunk should complete the message
      assert {:ok, events, <<>>} = AmazonBedrock.parse_stream_protocol(part2, buffer)
      assert length(events) == 1
    end
  end

  describe "attach_stream/4" do
    setup do
      model = Model.from!("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1"
      ]

      {:ok, model: model, context: context, opts: opts}
    end

    test "builds Finch.Request for streaming", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert %Finch.Request{} = finch_request
      assert finch_request.method == "POST"
      assert finch_request.path =~ "/model/"
      assert finch_request.path =~ "/invoke-with-response-stream"
    end

    test "includes proper headers", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      headers_map = Map.new(finch_request.headers)
      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert Map.has_key?(headers_map, "authorization")
    end

    test "signs request with AWS SigV4", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      # Check for AWS signature in authorization header
      auth_header = Enum.find(finch_request.headers, fn {k, _} -> k == "authorization" end)
      assert auth_header != nil
      {_, auth_value} = auth_header
      assert auth_value =~ "AWS4-HMAC-SHA256"
    end

    test "uses correct region", %{model: model, context: context, opts: opts} do
      custom_opts = Keyword.put(opts, :region, "eu-west-1")

      assert {:ok, finch_request} =
               AmazonBedrock.attach_stream(model, context, custom_opts, ReqLLM.Finch)

      assert finch_request.host =~ "eu-west-1"
    end
  end

  # Helper to build a valid AWS Event Stream message for testing
  defp build_aws_event_stream_message(payload) when is_binary(payload) do
    headers = <<>>
    headers_length = byte_size(headers)
    payload_length = byte_size(payload)
    total_length = 16 + headers_length + payload_length

    # Calculate prelude CRC
    prelude = <<total_length::32-big, headers_length::32-big>>
    prelude_crc = :erlang.crc32(prelude)

    # Calculate message CRC
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
