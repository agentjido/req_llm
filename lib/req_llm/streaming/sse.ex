defmodule ReqLLM.Streaming.SSE do
  @moduledoc """
  Provider-agnostic Server-Sent Events (SSE) parsing utilities.

  The streaming HTTP path feeds Finch chunks into `accumulate_and_parse/2`,
  which returns parsed SSE events and an opaque parser state for the next chunk.
  Complete enumerable bodies can use `parse_sse_stream/1` or `parse_sse_binary/1`.
  """

  alias ServerSentEvents.Parser

  @type parser_state :: %Parser{} | nil

  @doc """
  Parse a binary chunk and return complete SSE events with parser state.
  """
  @spec accumulate_and_parse(binary(), parser_state() | binary()) :: {[map()], parser_state()}
  def accumulate_and_parse(chunk, state) when is_binary(chunk) do
    Parser.parse(normalize_state(state), chunk)
  end

  @doc """
  Flush a parser state by supplying a terminating blank line.
  """
  @spec flush(parser_state() | term()) :: {[map()], parser_state() | term()}
  def flush(%Parser{} = state), do: Parser.parse(state, "\n\n")
  def flush(state), do: {[], state}

  @doc """
  Process a raw SSE event, attempting JSON decode of its `data` field.
  """
  @spec process_sse_event(map()) :: map() | nil
  def process_sse_event(%{data: data} = event) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) -> %{event | data: parsed}
      {:ok, _parsed} -> event
      {:error, _} -> event
    end
  end

  def process_sse_event(event), do: event

  @doc """
  Parse SSE events from a stream of binary chunks with boundary handling.
  """
  @spec parse_sse_stream(Enumerable.t()) :: Enumerable.t()
  def parse_sse_stream(stream) do
    stream
    |> ServerSentEvents.decode_stream()
    |> Stream.map(&process_sse_event/1)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Parse SSE events from a complete binary string.
  """
  @spec parse_sse_binary(binary()) :: [map()]
  def parse_sse_binary(binary) when is_binary(binary) do
    binary
    |> List.wrap()
    |> parse_sse_stream()
    |> Enum.to_list()
  end

  defp normalize_state(%Parser{} = state), do: state
  defp normalize_state(nil), do: %Parser{phase: :start}
  defp normalize_state(""), do: %Parser{phase: :start}

  defp normalize_state(buffer) when is_binary(buffer) do
    {[], state} = Parser.parse(%Parser{phase: :start}, buffer)
    state
  end
end
