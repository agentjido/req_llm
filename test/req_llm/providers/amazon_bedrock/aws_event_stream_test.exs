defmodule ReqLLM.Providers.AmazonBedrock.AWSEventStreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock.AWSEventStream

  describe "parse_binary/1" do
    test "parses valid AWS Event Stream message" do
      # Build a simple test message using the proper helper
      payload = Jason.encode!(%{"type" => "test", "data" => "hello"})
      binary = build_test_message(payload)

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
      # Just 4 bytes
      partial = <<0, 0, 0, 100>>

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
      # Bedrock wraps JSON in base64 encoded bytes
      inner_data = Jason.encode!(%{"type" => "content_block_delta", "delta" => %{"text" => "Hi"}})
      encoded = Base.encode64(inner_data)

      # Build the payload that contains base64 encoded inner data
      payload = Jason.encode!(%{"bytes" => encoded})

      binary = build_test_message(payload)

      # Parser should decode the base64 and parse the inner JSON
      assert {:ok, [event], <<>>} = AWSEventStream.parse_binary(binary)
      assert event["type"] == "content_block_delta"
      assert event["delta"]["text"] == "Hi"
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

    test "returns error for invalid prelude CRC" do
      payload = Jason.encode!(%{"data" => "test"})
      headers = <<>>
      headers_length = byte_size(headers)
      payload_length = byte_size(payload)

      # Use same formula as helper: 16 = prelude(12) + message_crc(4)
      message_length = 16 + headers_length + payload_length

      prelude = <<message_length::32-big, headers_length::32-big>>
      bad_prelude_crc = 0xDEADBEEF

      message_without_crc = <<
        prelude::binary,
        bad_prelude_crc::32,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)

      binary = <<
        message_length::32-big,
        headers_length::32-big,
        bad_prelude_crc::32,
        headers::binary,
        payload::binary,
        message_crc::32
      >>

      # When a single message has a bad CRC, recovery attempts but finds no valid events
      assert {:error, :no_valid_events} = AWSEventStream.parse_binary(binary)
    end

    test "returns error for invalid message CRC" do
      payload = Jason.encode!(%{"data" => "test"})
      headers = <<>>
      headers_length = byte_size(headers)
      payload_length = byte_size(payload)

      message_length = 16 + headers_length + payload_length

      prelude = <<message_length::32-big, headers_length::32-big>>
      prelude_crc = :erlang.crc32(prelude)

      bad_message_crc = 0xCAFEBABE

      binary = <<
        message_length::32-big,
        headers_length::32-big,
        prelude_crc::32,
        headers::binary,
        payload::binary,
        bad_message_crc::32
      >>

      # When a single message has a bad CRC, recovery attempts but finds no valid events
      assert {:error, :no_valid_events} = AWSEventStream.parse_binary(binary)
    end

    test "recovers from corrupted data by finding next valid event" do
      # Create a message with bad prelude CRC that will trigger recovery
      payload1 = Jason.encode!(%{"data" => "bad"})
      headers = <<>>
      headers_length = byte_size(headers)
      payload_length = byte_size(payload1)
      message_length = 16 + headers_length + payload_length

      prelude = <<message_length::32-big, headers_length::32-big>>
      bad_prelude_crc = 0xDEADBEEF

      message_without_crc = <<
        prelude::binary,
        bad_prelude_crc::32,
        headers::binary,
        payload1::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)

      bad_message = <<
        message_length::32-big,
        headers_length::32-big,
        bad_prelude_crc::32,
        headers::binary,
        payload1::binary,
        message_crc::32
      >>

      # Followed by a valid message
      payload2 = Jason.encode!(%{"data" => "recovered"})
      valid_message = build_test_message(payload2)

      binary = bad_message <> valid_message

      # Should skip bad message and find the valid one
      assert {:ok, [event], <<>>} = AWSEventStream.parse_binary(binary)
      assert event["data"] == "recovered"
    end

    test "returns error when no valid events found in corrupted stream" do
      # Create a message with bad CRC and no valid messages after
      payload = Jason.encode!(%{"data" => "bad"})
      headers = <<>>
      headers_length = byte_size(headers)
      payload_length = byte_size(payload)
      message_length = 16 + headers_length + payload_length

      prelude = <<message_length::32-big, headers_length::32-big>>
      bad_prelude_crc = 0xDEADBEEF

      message_without_crc = <<
        prelude::binary,
        bad_prelude_crc::32,
        headers::binary,
        payload::binary
      >>

      message_crc = :erlang.crc32(message_without_crc)

      bad_message = <<
        message_length::32-big,
        headers_length::32-big,
        bad_prelude_crc::32,
        headers::binary,
        payload::binary,
        message_crc::32
      >>

      assert {:error, :no_valid_events} = AWSEventStream.parse_binary(bad_message)
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
