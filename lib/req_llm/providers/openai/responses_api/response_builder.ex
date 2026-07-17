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

  @impl true
  def build_response(chunks, metadata, opts) do
    DefaultBuilder.build_response(chunks, normalize_metadata(chunks, metadata), opts)
  end

  @doc false
  @spec build_buffered_response([StreamChunk.t()], map(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def build_buffered_response(chunks, metadata, opts) do
    DefaultBuilder.build_buffered_response(chunks, metadata, opts)
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
