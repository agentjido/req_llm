defmodule ReqLLM.Bedrock.BidiStreamTest do
  @moduledoc """
  Unit tests for the request-side signing/framing and inbound decoding of the
  Bedrock bidirectional client. The live HTTP/2 transport is exercised end-to-end
  against real Bedrock; these cover the pure pieces.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Bedrock.BidiStream
  alias ReqLLM.Providers.AmazonBedrock.AWSAuthAdapter

  describe "sign_seed/5 region handling" do
    test "scopes the seed signature to the explicit region, not the credential region" do
      host = "bedrock-runtime.us-east-1.amazonaws.com"
      url = "https://#{host}/model/amazon.nova-sonic-v1:0/invoke-with-bidirectional-stream"

      {headers, sig} = BidiStream.sign_seed(creds(), "us-east-1", "bedrock", host, url)
      hmap = Map.new(headers)

      assert hmap["x-amz-content-sha256"] == "STREAMING-AWS4-HMAC-SHA256-EVENTS"
      assert hmap["authorization"] =~ "/us-east-1/bedrock/aws4_request"
      refute hmap["authorization"] =~ "us-west-2"
      assert String.match?(sig, ~r/^[0-9a-f]{64}$/)
    end
  end

  describe "build_inner/1 frame construction" do
    test "frames the event as a {\"bytes\": base64} chunk message with CRC-valid framing" do
      event = %{
        "event" => %{"sessionStart" => %{"inferenceConfiguration" => %{"maxTokens" => 8}}}
      }

      frame = BidiStream.build_inner(event)

      <<total::big-32, hlen::big-32, prelude_crc::big-32, _rest::binary>> = frame
      assert prelude_crc == :erlang.crc32(<<total::big-32, hlen::big-32>>)
      assert byte_size(frame) == total

      headers = binary_part(frame, 12, hlen)
      payload = binary_part(frame, 12 + hlen, total - 16 - hlen)
      <<msg_crc::big-32>> = binary_part(frame, byte_size(frame) - 4, 4)
      assert msg_crc == :erlang.crc32(binary_part(frame, 0, byte_size(frame) - 4))

      # application headers identify it as a JSON "chunk" event
      assert headers =~ ":content-type"
      assert headers =~ ":event-type"
      assert headers =~ "chunk"

      # payload is {"bytes": "<base64 of the event JSON>"}
      decoded = Jason.decode!(payload)
      assert Map.keys(decoded) == ["bytes"]
      assert Jason.decode!(Base.decode64!(decoded["bytes"])) == event
    end
  end

  describe "decode_inbound/1" do
    defp output_message(event) do
      payload = Jason.encode!(%{"bytes" => Base.encode64(Jason.encode!(event))})

      headers =
        AWSAuthAdapter.event_stream_encode_string_header(":content-type", "application/json") <>
          AWSAuthAdapter.event_stream_encode_string_header(":event-type", "chunk") <>
          AWSAuthAdapter.event_stream_encode_string_header(":message-type", "event")

      AWSAuthAdapter.event_stream_encode_message(headers, payload)
    end

    test "decodes a complete inbound message (unwrapping the bytes blob)" do
      event = %{"event" => %{"textOutput" => %{"content" => "hi"}}}
      assert BidiStream.decode_inbound(output_message(event)) == {[event], ""}
    end

    test "returns no events and keeps the buffer when data is incomplete" do
      msg = output_message(%{"event" => %{"x" => 1}})
      partial = binary_part(msg, 0, 12)
      assert {[], ^partial} = BidiStream.decode_inbound(partial)
    end

    test "decodes multiple concatenated messages" do
      a = %{"event" => %{"a" => 1}}
      b = %{"event" => %{"b" => 2}}
      assert {[^a, ^b], ""} = BidiStream.decode_inbound(output_message(a) <> output_message(b))
    end
  end

  defp creds do
    AWSAuthAdapter.credentials_struct(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      region: "us-west-2"
    )
  end
end
