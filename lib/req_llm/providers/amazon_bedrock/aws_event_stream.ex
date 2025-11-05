defmodule ReqLLM.Providers.AmazonBedrock.AWSEventStream do
  @moduledoc """
  Parser for the AWS Event Stream protocol, specialized for Amazon Bedrock.

  AWS Event Stream is a binary protocol used by various AWS services for streaming responses.
  It includes CRC checksums and a specific binary format for framing messages.

  This module provides functions to parse the binary stream into decoded events.

  ## Design Rationale: Bedrock Specialization

  This parser is **intentionally specialized for Amazon Bedrock** and is **not** a
  general-purpose AWS Event Stream parser. This design was chosen for **performance
  and convenience** within ReqLLM.

  A generic parser would be less efficient for this use case. It would have to:
  1. Parse all 10+ possible header types (e.g., UUIDs, Timestamps, Booleans) that
     Bedrock never uses, adding unnecessary parsing overhead.
  2. Return a raw binary payload, forcing ReqLLM to perform a second, multi-step
     decoding process (JSON decode → extract base64 → base64 decode → JSON decode).

  This implementation avoids that overhead by making two key assumptions:

  1. **Header Parsing:** Only parses header values of type `7` (String), which is all
     Bedrock uses for metadata like `:event-type` and `:content-type`. All other
     header value types defined in the AWS Event Stream specification are intentionally
     ignored, simplifying the parsing logic.

  2. **Integrated Payload Decoding:** Decodes the Bedrock-specific payload format
     *in a single pass*. It handles both the `InvokeModelWithResponseStream` format
     (`{\"bytes\": \"base64...\"}`) and the `ConverseStream` direct JSON format,
     returning ready-to-use Elixir maps.

  ## Non-Goals

  Because of this specialization, this parser is **not suitable** for other AWS services
  that use the Event Stream protocol, such as:
  - **S3 Select** (uses different header types and binary payloads)
  - **Amazon Transcribe** (uses non-JSON binary payloads)
  - **Amazon Kinesis** (different event structure)

  For a general-purpose parser, consider implementing all header types and returning
  raw payload bytes instead of decoded JSON.

  ## Format

  Each event in the stream has the following structure:
  - 4 bytes: total message length (big-endian)
  - 4 bytes: headers length (big-endian)
  - 4 bytes: prelude CRC32
  - N bytes: headers (key-value pairs)
  - M bytes: payload/body
  - 4 bytes: message CRC32

  ## Example

      data = <<binary_aws_event_stream_data>>
      case ReqLLM.Providers.AmazonBedrock.AWSEventStream.parse_binary(data) do
        {:ok, events, rest} ->
          # Process events (list of decoded JSON maps)
          # Keep rest for next chunk
        {:incomplete, data} ->
          # Need more data, buffer it
        {:error, reason} ->
          # Handle error
      end
  """

  @uint32_size 4
  @checksum_size 4
  # message_length + headers_length + prelude_crc
  @prelude_length @uint32_size * 3
  @min_message_length @prelude_length + @checksum_size

  @doc """
  Parse binary AWS event stream data into decoded events.

  Returns:
  - `{:ok, events, rest}` - Successfully parsed events with remaining data
  - `{:incomplete, data}` - Not enough data to parse complete event
  - `{:error, reason}` - Parse error
  """
  def parse_binary(data) when is_binary(data) do
    parse_events(data, [])
  end

  defp parse_events(<<>>, acc) do
    {:ok, Enum.reverse(acc), <<>>}
  end

  defp parse_events(data, _acc) when byte_size(data) < @prelude_length do
    # Not enough data for a complete header
    {:incomplete, data}
  end

  defp parse_events(data, acc) do
    case parse_single_event(data) do
      {:ok, event, rest} ->
        parse_events(rest, [event | acc])

      {:incomplete, _data} ->
        # Return what we have so far
        if acc == [] do
          {:incomplete, data}
        else
          {:ok, Enum.reverse(acc), data}
        end

      {:error, _reason} ->
        # Skip corrupted event and attempt recovery
        skip_to_next_event(data, acc)
    end
  end

  defp parse_single_event(data) when byte_size(data) >= @prelude_length do
    <<
      message_length::big-32,
      headers_length::big-32,
      prelude_crc::32,
      rest::binary
    >> = data

    if message_length >= @min_message_length do
      # Calculate body length
      # message_length includes EVERYTHING in the message
      # Total = prelude(@prelude_length) + headers + body + message_crc(@checksum_size)
      # So body = total - prelude - headers - message_crc
      body_length = message_length - @prelude_length - headers_length - @checksum_size

      # Check if we have the complete message
      total_needed = headers_length + body_length + @checksum_size

      if byte_size(rest) >= total_needed and body_length >= 0 do
        <<
          headers::binary-size(headers_length),
          body::binary-size(body_length),
          message_crc::32,
          remaining::binary
        >> = rest

        # Verify prelude CRC
        prelude = <<message_length::big-32, headers_length::big-32>>

        if :erlang.crc32(prelude) == prelude_crc do
          # Verify message CRC
          message_without_crc = <<
            prelude::binary,
            prelude_crc::32,
            headers::binary,
            body::binary
          >>

          if :erlang.crc32(message_without_crc) == message_crc do
            # Parse headers to get event metadata
            parsed_headers = parse_headers(headers)

            # Parse the body - typically JSON with base64-encoded content
            case decode_body(body, parsed_headers) do
              {:ok, decoded} ->
                {:ok, decoded, remaining}

              {:error, reason} ->
                {:error, {:decode_error, reason}}
            end
          else
            {:error, :invalid_message_crc}
          end
        else
          {:error, :invalid_prelude_crc}
        end
      else
        # Not enough data, return the original data unchanged
        {:incomplete, data}
      end
    else
      # Invalid message length
      {:error, :invalid_message_length}
    end
  end

  defp parse_single_event(data) do
    {:incomplete, data}
  end

  defp parse_headers(headers_binary) when byte_size(headers_binary) == 0 do
    %{}
  end

  defp parse_headers(headers_binary) do
    parse_header_pairs(headers_binary, %{})
  end

  defp parse_header_pairs(<<>>, acc), do: acc

  defp parse_header_pairs(data, acc) do
    # Each header is: name_len(1) + name + value_type(1) + value_len(2) + value
    case data do
      <<name_len::8, rest::binary>> when byte_size(rest) >= name_len ->
        <<name::binary-size(name_len), value_type::8, rest2::binary>> = rest

        case value_type do
          # String type (7)
          7 when byte_size(rest2) >= 2 ->
            <<value_len::16-big, rest3::binary>> = rest2

            if byte_size(rest3) >= value_len do
              <<value::binary-size(value_len), remaining::binary>> = rest3
              parse_header_pairs(remaining, Map.put(acc, name, value))
            else
              acc
            end

          # Other types not implemented yet
          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp decode_body(body, headers) do
    # AWS event streams for Bedrock typically have {"bytes": "base64_content"}
    # where the base64 content is the actual JSON payload
    case Jason.decode(body) do
      {:ok, %{"bytes" => encoded}} ->
        # Bedrock-specific: base64-encoded JSON
        case Base.decode64(encoded) do
          {:ok, decoded} ->
            Jason.decode(decoded)

          :error ->
            {:error, :base64_decode_error}
        end

      {:ok, decoded} ->
        # Direct JSON (some AWS services)
        # For Converse API, wrap in event type from headers if present
        case Map.get(headers, ":event-type") do
          nil ->
            {:ok, decoded}

          event_type ->
            # Convert "contentBlockDelta" to the wrapper format expected by parse_stream_chunk
            {:ok, %{event_type => decoded}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp skip_to_next_event(data, acc) do
    # Scan for next valid event boundary to recover from corrupted data
    case find_next_event_boundary(data) do
      {:ok, next_data} ->
        parse_events(next_data, acc)

      :not_found ->
        if acc == [] do
          # If we couldn't recover and have no valid events
          {:error, :no_valid_events}
        else
          {:ok, Enum.reverse(acc), <<>>}
        end
    end
  end

  defp find_next_event_boundary(<<_::8, rest::binary>>) do
    # Skip one byte at a time looking for valid event header
    # Look for reasonable message length and verify we have enough data
    case rest do
      <<length::big-32, _::binary>> = data
      when length >= @min_message_length and length <= 100_000 and byte_size(data) >= length ->
        # We have a plausible message length AND enough bytes for a complete message
        {:ok, data}

      _ ->
        find_next_event_boundary(rest)
    end
  end

  defp find_next_event_boundary(<<>>) do
    :not_found
  end

  @doc """
  Create a Stream that processes AWS event stream chunks from a process mailbox.

  This is useful when using Req's `:into :self` option to collect streaming responses.
  The stream will receive messages of the form `{ref, {:data, chunk}}` and `{ref, :done}`.

  ## Options

  - `:timeout` - Timeout in milliseconds waiting for chunks (default: 5000)
  - `:process_event` - Function to process each decoded event (default: identity)

  ## Example

      stream = ReqLLM.Providers.AmazonBedrock.AWSEventStream.create_stream(
        process_event: fn event ->
          # Transform the event
          %{data: event}
        end
      )

      Enum.each(stream, fn chunk ->
        IO.inspect(chunk)
      end)
  """
  def create_stream(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    process_event = Keyword.get(opts, :process_event, &Function.identity/1)

    Stream.resource(
      fn ->
        # Initial state: buffer and pid
        {"", self()}
      end,
      fn
        {buffer, pid} ->
          receive do
            {_ref, {:data, chunk}} when is_binary(chunk) ->
              handle_chunk(buffer, chunk, pid, process_event)

            {{_pool, _pid}, {:data, chunk}} when is_binary(chunk) ->
              # Finch format when using :into :self
              handle_chunk(buffer, chunk, pid, process_event)

            {_ref, :done} ->
              # Stream is done
              {:halt, buffer}

            {{_pool, _pid}, :done} ->
              # Finch format for done signal
              {:halt, buffer}

            _ ->
              # Unknown message, continue
              {[], {buffer, pid}}
          after
            timeout ->
              # Timeout waiting for chunks
              {:halt, buffer}
          end

        :halt ->
          {:halt, nil}
      end,
      fn _ -> :ok end
    )
  end

  # Handle incoming data chunks
  defp handle_chunk(buffer, chunk, pid, process_event_fun) when is_binary(chunk) do
    data = buffer <> chunk

    case parse_binary(data) do
      {:ok, events, rest} ->
        # Process and emit events
        processed = Enum.map(events, process_event_fun)
        {processed, {rest, pid}}

      {:incomplete, data} ->
        # Need more data, buffer it
        {[], {data, pid}}

      {:error, _reason} ->
        # Skip bad data, reset buffer
        {[], {"", pid}}
    end
  end
end
