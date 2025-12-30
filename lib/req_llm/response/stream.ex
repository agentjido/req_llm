defmodule ReqLLM.Response.Stream do
  @moduledoc """
  Stream processing utilities for ReqLLM responses.

  This module contains helper functions for working with streaming responses,
  particularly for joining stream chunks into complete responses.
  """

  alias ReqLLM.{Message, Response, StreamChunk}

  require Logger

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

  ## Examples

      chunks = Enum.to_list(stream_response.stream)
      summary = ReqLLM.Response.Stream.summarize(chunks)
      summary.text        #=> "Hello, world!"
      summary.tool_calls  #=> [%{id: "call_123", name: "get_weather", arguments: %{...}}]

  """
  @spec summarize(Enumerable.t(StreamChunk.t())) :: summary()
  def summarize(chunks) do
    chunks_list = if is_list(chunks), do: chunks, else: Enum.to_list(chunks)

    acc =
      Enum.reduce(
        chunks_list,
        %{
          text_content: [],
          thinking_content: [],
          tool_calls: [],
          arg_fragments: %{},
          finish_reason: nil,
          usage: nil
        },
        &accumulate_chunk/2
      )

    tool_calls = reconstruct_tool_calls(acc)

    %{
      text: acc.text_content |> Enum.reverse() |> Enum.join(""),
      thinking: acc.thinking_content |> Enum.reverse() |> Enum.join(""),
      tool_calls: tool_calls,
      finish_reason: normalize_finish_reason(acc.finish_reason),
      usage: acc.usage
    }
  end

  defp accumulate_chunk(%StreamChunk{type: :content, text: text}, acc) do
    %{acc | text_content: [text | acc.text_content]}
  end

  defp accumulate_chunk(%StreamChunk{type: :thinking, text: text}, acc) do
    %{acc | thinking_content: [text | acc.thinking_content]}
  end

  defp accumulate_chunk(%StreamChunk{type: :tool_call} = chunk, acc) do
    tool_call = %{
      id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
      name: chunk.name,
      arguments: chunk.arguments || %{},
      index: Map.get(chunk.metadata, :index, 0)
    }

    %{acc | tool_calls: [tool_call | acc.tool_calls]}
  end

  defp accumulate_chunk(%StreamChunk{type: :meta, metadata: meta}, acc) do
    acc = handle_tool_call_args(meta, acc)
    acc = handle_finish_reason(meta, acc)
    handle_usage(meta, acc)
  end

  defp accumulate_chunk(_chunk, acc), do: acc

  defp handle_tool_call_args(%{tool_call_args: %{index: index, fragment: fragment}}, acc) do
    existing = Map.get(acc.arg_fragments, index, "")
    %{acc | arg_fragments: Map.put(acc.arg_fragments, index, existing <> fragment)}
  end

  defp handle_tool_call_args(_meta, acc), do: acc

  defp handle_finish_reason(%{finish_reason: reason}, acc) when not is_nil(reason) do
    %{acc | finish_reason: reason}
  end

  defp handle_finish_reason(_meta, acc), do: acc

  defp handle_usage(%{usage: usage}, acc) when is_map(usage) do
    merged = Map.merge(acc.usage || %{}, usage)
    %{acc | usage: merged}
  end

  defp handle_usage(_meta, acc), do: acc

  defp reconstruct_tool_calls(%{tool_calls: []}), do: []

  defp reconstruct_tool_calls(acc) do
    acc.tool_calls
    |> Enum.reverse()
    |> Enum.map(&merge_tool_call_arguments(&1, acc.arg_fragments))
  end

  defp merge_tool_call_arguments(tool_call, arg_fragments) do
    case Map.get(arg_fragments, tool_call.index) do
      nil ->
        Map.delete(tool_call, :index)

      json_str ->
        case Jason.decode(json_str) do
          {:ok, args} ->
            tool_call
            |> Map.put(:arguments, args)
            |> Map.delete(:index)

          {:error, _} ->
            Map.delete(tool_call, :index)
        end
    end
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
        Map.get(chunk.metadata || %{}, :usage) || Map.get(chunk.metadata || %{}, "usage") || %{}

      Map.merge(acc || %{}, usage)
    end)
  end
end
