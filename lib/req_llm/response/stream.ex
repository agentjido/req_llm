defmodule ReqLLM.Response.Stream do
  @moduledoc """
  Stream processing utilities for ReqLLM responses.

  This module contains helper functions for working with streaming responses,
  particularly for joining stream chunks into complete responses.
  """

  alias ReqLLM.{Message, Response}
  alias ReqLLM.Provider.ChunkAccumulator

  @typedoc """
  Summary of accumulated stream data.

  Contains all the extracted content from a stream of chunks, suitable for
  building responses or classifying stream results.
  """
  @type summary :: %{
          text: String.t(),
          thinking: String.t(),
          tool_calls: [map()],
          finish_reason: atom() | nil,
          usage: map() | nil
        }

  @doc """
  Summarize a stream of chunks into accumulated data.

  Processes all chunks and returns a map with:
  - `text` - Accumulated text content
  - `thinking` - Accumulated thinking/reasoning content
  - `tool_calls` - List of reconstructed tool calls with merged argument fragments
  - `finish_reason` - The finish reason from metadata chunks (normalized to atom)
  - `usage` - Token usage statistics from metadata chunks

  This function is the shared core for both `join/2` and `ReqLLM.Stream.ToolCalls`.
  It delegates accumulation to `ReqLLM.Provider.ChunkAccumulator` so the
  streaming chunk reducer stays a single source of truth.

  ## Examples

      chunks = Enum.to_list(stream_response.stream)
      summary = ReqLLM.Response.Stream.summarize(chunks)
      summary.text        #=> "Hello, world!"
      summary.tool_calls  #=> [%{id: "call_123", name: "get_weather", arguments: %{...}}]

  """
  @spec summarize(Enumerable.t()) :: summary()
  def summarize(chunks) do
    chunks_list = if is_list(chunks), do: chunks, else: Enum.to_list(chunks)
    acc = ChunkAccumulator.reduce(ChunkAccumulator.new(), chunks_list)

    %{
      text: ChunkAccumulator.finalize_text(acc),
      thinking: ChunkAccumulator.finalize_thinking(acc),
      tool_calls: ChunkAccumulator.finalize_tool_calls_for_response(acc),
      finish_reason: normalize_finish_reason(ChunkAccumulator.finalize_finish_reason(acc)),
      usage: ChunkAccumulator.finalize_usage(acc)
    }
  end

  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(reason) when is_atom(reason), do: reason
  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("completed"), do: :stop
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("max_tokens"), do: :length
  defp normalize_finish_reason("max_output_tokens"), do: :length
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason("tool_use"), do: :tool_calls
  defp normalize_finish_reason("end_turn"), do: :stop
  defp normalize_finish_reason("error"), do: :error
  defp normalize_finish_reason("cancelled"), do: :cancelled
  defp normalize_finish_reason("incomplete"), do: :incomplete
  defp normalize_finish_reason(_other), do: :unknown

  @doc """
  Join a stream of chunks into a complete response.

  This function consumes the entire stream, builds the complete message from content chunks,
  and returns a new response with the stream consumed and message populated.

  ## Implementation Notes

  The joining process involves several steps:
  1. Collect all stream chunks by consuming the enumerable
  2. Filter and concatenate content chunks to build the response text
  3. Extract final usage statistics from meta chunks, merging with existing usage
  4. Build a complete assistant message with the concatenated text content
  5. Return an updated response with materialized data and stream cleared

  ## Parameters

    * `stream` - The stream enumerable containing stream chunks
    * `response` - The original response to update with materialized data

  ## Returns

    * `{:ok, updated_response}` on success
    * `{:error, %ReqLLM.Error.API.Stream{}}` on stream processing failure
  """
  @spec join(Enumerable.t(), Response.t()) :: {:ok, Response.t()} | {:error, term()}
  def join(stream, %Response{} = response) do
    chunks = Enum.to_list(stream)

    content_text = build_content_text(chunks)
    final_usage = merge_usage_from_chunks(chunks, response.usage)

    message = %Message{
      role: :assistant,
      content: [%{type: :text, text: content_text}],
      metadata: %{}
    }

    updated_response = %{
      response
      | message: message,
        usage: final_usage,
        stream?: false,
        stream: nil
    }

    {:ok, updated_response}
  rescue
    error ->
      {:error,
       %ReqLLM.Error.API.Stream{
         reason: "Stream processing failed: #{Exception.message(error)}",
         cause: error
       }}
  end

  defp build_content_text(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :content))
    |> Enum.map_join("", & &1.text)
  end

  defp merge_usage_from_chunks(chunks, existing_usage) do
    chunks
    |> Enum.filter(&(&1.type == :meta))
    |> Enum.reduce(existing_usage, fn chunk, acc ->
      usage =
        Map.get(chunk.metadata || %{}, :usage, %{})

      ReqLLM.Usage.merge(acc || %{}, usage)
    end)
  end
end
