defmodule ReqLLM.Response.Stream do
  @moduledoc """
  Stream processing utilities for ReqLLM responses.

  This module contains helper functions for working with streaming responses,
  particularly for joining stream chunks into complete responses.
  """

  alias ReqLLM.{Message, Response}

  require Logger

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
