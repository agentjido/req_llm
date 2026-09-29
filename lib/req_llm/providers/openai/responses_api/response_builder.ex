defmodule ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder do
  @moduledoc """
  OpenAI Responses API-specific ResponseBuilder implementation.

  Handles Responses API-specific requirements:
  - Detects tool calls and corrects finish_reason from :stop to :tool_calls
  - Propagates `response_id` to message metadata for stateless multi-turn
  - Preserves tool call IDs for function outputs

  This fixes:
  - Bug #270: streaming responses lost the `response_id` needed for multi-turn
  - Streaming finish_reason parity: API returns "completed" even with tool calls
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @summary_part_separator "\n\n"

  @impl true
  def build_response(chunks, metadata, opts) do
    with {:ok, response} <-
           DefaultBuilder.build_response(
             render_summary_boundaries(chunks),
             normalize_metadata(chunks, metadata),
             opts
           ) do
      {:ok, preserve_compaction_replay(response, chunks, metadata, opts)}
    end
  end

  defp render_summary_boundaries(chunks) do
    {rendered, _last_part} =
      Enum.map_reduce(chunks, nil, fn
        %StreamChunk{type: :thinking, text: text, metadata: %{summary_index: index} = meta} =
            chunk,
        last_part
        when is_integer(index) and is_binary(text) and text != "" ->
          part = {meta[:item_id], meta[:output_index], index}

          rendered =
            if last_part != nil and last_part != part do
              separator =
                ReqLLM.Message.ContentPart.thinking(@summary_part_separator)
                |> StreamChunk.content_part()

              [separator, chunk]
            else
              [chunk]
            end

          {rendered, part}

        chunk, last_part ->
          {[chunk], last_part}
      end)

    List.flatten(rendered)
  end

  @doc false
  @spec build_buffered_response([StreamChunk.t()], map(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def build_buffered_response(chunks, metadata, opts) do
    DefaultBuilder.build_buffered_response(chunks, metadata, opts)
  end

  defp preserve_compaction_replay(response, chunks, metadata, opts) do
    replay =
      metadata[:responses_replay] ||
        Enum.find_value(Enum.reverse(chunks), & &1.metadata[:responses_replay])

    if replay do
      message = %{
        response.message
        | metadata: Map.put(response.message.metadata, :responses_replay, replay)
      }

      ReqLLM.Context.merge_response(Keyword.fetch!(opts, :context), %{response | message: message})
    else
      response
    end
  end

  defp normalize_metadata(chunks, metadata) do
    has_actionable_tool_calls? = Enum.any?(chunks, &actionable_tool_call_chunk?/1)

    if has_actionable_tool_calls? and finish_reason_is_stop?(metadata[:finish_reason]) do
      Map.put(metadata, :finish_reason, :tool_calls)
    else
      metadata
    end
  end

  defp finish_reason_is_stop?(:stop), do: true
  defp finish_reason_is_stop?("stop"), do: true
  defp finish_reason_is_stop?(_), do: false

  defp actionable_tool_call_chunk?(%StreamChunk{type: :tool_call, metadata: meta}) do
    not ToolCall.flagged_builtin?(meta)
  end

  defp actionable_tool_call_chunk?(_), do: false
end
