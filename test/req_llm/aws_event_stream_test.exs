defmodule ReqLLM.AWSEventStreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.AWSEventStream

  describe "parse_binary/1" do
    test "parses valid AWS Event Stream message" do
      # Build a simple test message
      # Message structure: total_length | headers_length | prelude_crc | headers | payload | message_crc

      # For this test, we'll create a minimal message with no headers
      headers = <<>>
      payload = Jason.encode!(%{"type" => "test", "data" => "hello"})

      headers_length = byte_size(headers)
      payload_length = byte_size(payload)
      total_length = 16 + headers_length + payload_length  # 16 = prelude(12) + message_crc(4)

      # Calculate CRCs (simplified - using 0 for test)
      prelude_crc = 0
      message_crc = 0

      binary = <<
        total_length::32-big,
        headers_length::32-big,
        prelude_crc::32-big,
        headers::binary,
        payload::binary,
        message_crc::32-big
      >>

      assert {:ok, events, rest} = AWSEventStream.parse_binary(binary)
      assert length(events) == 1
      assert rest == <<>>

      [event] = events
      assert is_map(event)
      assert event["type"] == "test"
      assert event["data"] == "hello"
    end

    test "returns incomplete when not enough data" do
      # Only provide part of the prelude
      partial = <<0, 0, 0, 100>>  # Just 4 bytes

      assert {:incomplete, ^partial} = AWSEventStream.parse_binary(partial)
    end

    test "handles empty binary" do
      assert {:ok, [], <<>>} = AWSEventStream.parse_binary(<<>>)
    end

    test "parses multiple messages" do
      # Create two minimal messages
      payload1 = Jason.encode!(%{"chunk" => 1})
      payload2 = Jason.encode!(%{"chunk" => 2})

      msg1 = build_test_message(payload1)
      msg2 = build_test_message(payload2)

      binary = msg1 <> msg2

      assert {:ok, events, <<>>} = AWSEventStream.parse_binary(binary)
      assert length(events) == 2
    end

    test "handles Bedrock chunk format with base64 bytes" do
      # Bedrock wraps JSON in a chunk with base64 encoded bytes
      inner_data = Jason.encode!(%{"type" => "content_block_delta", "delta" => %{"text" => "Hi"}})
      encoded = Base.encode64(inner_data)
      payload = Jason.encode!(%{"chunk" => %{"bytes" => encoded}})

      binary = build_test_message(payload)

      assert {:ok, [event], <<>>} = AWSEventStream.parse_binary(binary)
      assert event["chunk"]["bytes"] == encoded
    end

    test "returns incomplete for message split across chunks" do
      # Create a message that's split
      payload = Jason.encode!(%{"data" => "test"})
      full_message = build_test_message(payload)

      # Take only half the message
      split_point = div(byte_size(full_message), 2)
      partial = binary_part(full_message, 0, split_point)

      result = AWSEventStream.parse_binary(partial)
      assert match?({:incomplete, _}, result)
    end
  end

  # Helper to build a valid AWS Event Stream message with proper CRCs
  defp build_test_message(payload) when is_binary(payload) do
    headers = <<>>
    headers_length = byte_size(headers)
    payload_length = byte_size(payload)
    total_length = 16 + headers_length + payload_length

    # Calculate prelude CRC
    prelude = <<total_length::32-big, headers_length::32-big>>
    prelude_crc = :erlang.crc32(prelude)

    # Calculate message CRC (everything except the final message CRC itself)
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
