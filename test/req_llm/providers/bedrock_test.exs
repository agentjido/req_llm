defmodule ReqLLM.Providers.BedrockTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Model, Context, Providers.Bedrock}

  describe "provider basics" do
    test "provider_id returns :bedrock" do
      assert Bedrock.provider_id() == :bedrock
    end

    test "default_base_url returns Bedrock endpoint format" do
      url = Bedrock.default_base_url()
      assert url =~ "bedrock-runtime"
      assert url =~ "amazonaws.com"
    end
  end

  describe "model family detection" do
    test "correctly identifies Anthropic models" do
      assert Bedrock.get_model_family("anthropic.claude-3-sonnet-20240229-v1:0") == "anthropic"
      assert Bedrock.get_model_family("anthropic.claude-3-opus-20240229-v1:0") == "anthropic"
    end

    test "handles region-prefixed model IDs (us., eu., ap., ca.)" do
      for prefix <- ["us", "eu", "ap", "ca"] do
        model_id = "#{prefix}.anthropic.claude-3-sonnet-20240229-v1:0"
        assert Bedrock.get_model_family(model_id) == "anthropic"
      end
    end

    test "raises error for unsupported Meta models" do
      assert_raise ArgumentError, ~r/Model family 'meta' is not yet supported/, fn ->
        Bedrock.get_model_family("meta.llama3-70b-instruct-v1:0")
      end
    end

    test "raises error for unsupported Amazon models" do
      assert_raise ArgumentError, ~r/Model family 'amazon' is not yet supported/, fn ->
        Bedrock.get_model_family("amazon.nova-pro-v1:0")
      end
    end

    test "raises error for unsupported Cohere models" do
      assert_raise ArgumentError, ~r/Model family 'cohere' is not yet supported/, fn ->
        Bedrock.get_model_family("cohere.command-r-v1:0")
      end
    end

    test "raises error for unknown model families" do
      assert_raise ArgumentError, ~r/Unknown model family/, fn ->
        Bedrock.get_model_family("unknown.model-v1")
      end
    end
  end

  describe "AWS credentials handling" do
    test "attach_stream raises when credentials missing" do
      model = Model.from!("bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new() |> Context.add_message(:user, "Test")

      assert_raise ArgumentError, ~r/AWS credentials required/, fn ->
        Bedrock.attach_stream(model, context, [], ReqLLM.Finch)
      end
    end
  end

  describe "parse_stream_protocol/2" do
    test "parses AWS Event Stream binary data" do
      # Create a simple AWS Event Stream message
      payload = Jason.encode!(%{"type" => "chunk", "data" => "test"})
      binary = build_aws_event_stream_message(payload)

      assert {:ok, events, rest} = Bedrock.parse_stream_protocol(binary, <<>>)
      assert length(events) > 0
      assert rest == <<>>
    end

    test "handles incomplete data" do
      partial = <<0, 0, 0, 100>>  # Incomplete prelude

      assert {:incomplete, buffer} = Bedrock.parse_stream_protocol(partial, <<>>)
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
      assert {:incomplete, buffer} = Bedrock.parse_stream_protocol(part1, <<>>)

      # Second chunk should complete the message
      assert {:ok, events, <<>>} = Bedrock.parse_stream_protocol(part2, buffer)
      assert length(events) == 1
    end
  end

  describe "attach_stream/4" do
    setup do
      model = Model.from!("bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new() |> Context.add_message(:user, "Hello")

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1"
      ]

      {:ok, model: model, context: context, opts: opts}
    end

    test "builds Finch.Request for streaming", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} = Bedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      assert %Finch.Request{} = finch_request
      assert finch_request.method == :post
      assert finch_request.path =~ "/model/"
      assert finch_request.path =~ "/invoke-with-response-stream"
    end

    test "includes proper headers", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} = Bedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      headers_map = Map.new(finch_request.headers)
      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "application/vnd.amazon.eventstream"
      assert Map.has_key?(headers_map, "authorization")
    end

    test "signs request with AWS SigV4", %{model: model, context: context, opts: opts} do
      assert {:ok, finch_request} = Bedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      # Check for AWS signature in authorization header
      auth_header = Enum.find(finch_request.headers, fn {k, _} -> k == "authorization" end)
      assert auth_header != nil
      {_, auth_value} = auth_header
      assert auth_value =~ "AWS4-HMAC-SHA256"
    end

    test "uses correct region", %{model: model, context: context, opts: opts} do
      custom_opts = Keyword.put(opts, :region, "eu-west-1")
      assert {:ok, finch_request} = Bedrock.attach_stream(model, context, custom_opts, ReqLLM.Finch)

      assert finch_request.host =~ "eu-west-1"
    end

    test "raises error when credentials missing", %{model: model, context: context} do
      assert_raise ArgumentError, ~r/AWS credentials required/, fn ->
        Bedrock.attach_stream(model, context, [], ReqLLM.Finch)
      end
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