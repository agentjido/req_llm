defmodule ReqLLM.Streaming.SSE do
  @moduledoc """
  Provider-agnostic Server-Sent Events (SSE) parsing utilities.

  This module provides core SSE parsing functionality that can be used
  across different streaming implementations without Req dependencies.
  It handles chunk boundary parsing, JSON decoding, and event processing.

  ## Purpose

  Provides reusable SSE utilities for the streaming architecture. 
  This module focuses solely on
  SSE parsing and does not include HTTP transport concerns.

  ## Usage

      # Parse SSE events from accumulated chunks
      {events, remaining_buffer} = ReqLLM.Streaming.SSE.accumulate_and_parse(chunk, buffer)

      # Process individual SSE events (JSON decode if possible)
      processed_event = ReqLLM.Streaming.SSE.process_sse_event(raw_event)

  ## Examples

      # Handle chunk boundary parsing
      buffer = ""
      {events1, buffer} = ReqLLM.Streaming.SSE.accumulate_and_parse("data: {partial", buffer)
      # events1 = [] (no complete events yet)
      
      {events2, buffer} = ReqLLM.Streaming.SSE.accumulate_and_parse("json}\\n\\n", buffer)  
      # events2 = [%{data: "{partialjson}"}] (complete event parsed)

      # Process events with JSON decoding
      raw_event = %{data: "{\\"text\\": \\"hello\\"}"}
      processed = ReqLLM.Streaming.SSE.process_sse_event(raw_event)
      # => %{data: %{"text" => "hello"}}

  """

  require Logger

  @doc """
  Accumulate HTTP chunks and parse complete SSE events.

  Handles SSE event boundaries that may span multiple HTTP chunks by
  maintaining a buffer of incomplete data. Uses the ServerSentEvents
  library for actual parsing.

  ## Parameters
    - `chunk` - New HTTP chunk data (binary)
    - `buffer` - Previously accumulated incomplete data (binary)

  ## Returns
    - `{events, remaining_buffer}` where events is a list of parsed 
      SSE event maps and remaining_buffer is any incomplete data

  ## Examples

      # First chunk contains incomplete event
      {[], buffer} = accumulate_and_parse("data: {incomplete", "")
      
      # Second chunk completes the event  
      {[event], ""} = accumulate_and_parse(" json}\\n\\n", buffer)

  """
  @spec accumulate_and_parse(binary(), binary()) :: {[map()], binary()}
  def accumulate_and_parse(chunk, buffer) do
    combined = buffer <> chunk
    ServerSentEvents.parse(combined)
  end

  @doc """
  Process a raw SSE event, attempting JSON decode of data field.

  Takes a raw SSE event map and attempts to JSON decode the data field.
  If JSON parsing succeeds, replaces the data field with the parsed object.
  If parsing fails, returns the event unchanged.

  ## Parameters
    - `event` - Raw SSE event map with string data field

  ## Returns
    - Processed event map with JSON-decoded data field (if successful)

  ## Examples

      # Successful JSON decode
      raw = %{data: "{\\"message\\": \\"hello\\"}"}
      process_sse_event(raw)
      # => %{data: %{"message" => "hello"}}

      # Invalid JSON - returned unchanged
      raw = %{data: "invalid json"}  
      process_sse_event(raw)
      # => %{data: "invalid json"}

      # Non-string data - returned unchanged
      raw = %{data: nil}
      process_sse_event(raw)  
      # => %{data: nil}

  """
  @spec process_sse_event(map()) :: map() | nil
  def process_sse_event(%{data: data} = event) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) -> %{event | data: parsed}
      {:error, _} -> event
    end
  end

  def process_sse_event(event), do: event

  @doc """
  Parse SSE events from a stream of chunks with boundary handling.

  Transforms a stream of HTTP chunks into a stream of parsed SSE events,
  handling event boundaries that span multiple chunks.

  ## Parameters
    - `stream` - Stream of HTTP chunks (binary data)

  ## Returns
    - Stream of parsed SSE event maps

  ## Examples

      chunks = ["data: {first", " event}\\n\\ndata: {second event}\\n\\n"]
      events = parse_sse_stream(Stream.from_list(chunks)) |> Enum.to_list()
      # => [%{data: "{first event}"}, %{data: "{second event}"}]

  """
  @spec parse_sse_stream(Enumerable.t()) :: Enumerable.t()
  def parse_sse_stream(stream) do
    stream
    |> Stream.transform("", fn chunk, buffer ->
      {events, new_buffer} = accumulate_and_parse(chunk, buffer)
      # Events is already a list, no need to wrap
      {events, new_buffer}
    end)
    |> Stream.map(&process_sse_event/1)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Parse SSE events from a complete binary string.

  Parses all SSE events from a complete binary string in one operation.
  Useful for testing or when you have the complete SSE response.

  ## Parameters
    - `binary` - Complete SSE response as binary

  ## Returns
    - List of parsed SSE event maps

  ## Examples

      binary = "data: {\\"msg\\": \\"hello\\"}\\n\\ndata: [DONE]\\n\\n"
      events = parse_sse_binary(binary)
      # => [%{data: %{"msg" => "hello"}}, %{data: "[DONE]"}]

  """
  @spec parse_sse_binary(binary()) :: [map()]
  def parse_sse_binary(binary) when is_binary(binary) do
    {events, _remaining} = ServerSentEvents.parse(binary)

    events
    |> Enum.map(&process_sse_event/1)
    |> Enum.reject(&is_nil/1)
  end
end
