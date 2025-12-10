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

  @impl true
  def build_response(chunks, metadata, opts) do
    # Check if any chunks are tool calls
    has_tool_calls? = Enum.any?(chunks, &tool_call_chunk?/1)

    # Override finish_reason if we have tool calls but finish_reason is :stop
    # The Responses API returns "completed" status even when tool calls are present
    metadata =
      if has_tool_calls? and finish_reason_is_stop?(metadata[:finish_reason]) do
        Map.put(metadata, :finish_reason, :tool_calls)
      else
        metadata
      end

    # Build base response using default implementation
    case DefaultBuilder.build_response(chunks, metadata, opts) do
      {:ok, response} ->
        # Apply Responses API-specific post-processing
        {:ok, propagate_response_id(response, metadata)}

      error ->
        error
    end
  end

  defp finish_reason_is_stop?(:stop), do: true
  defp finish_reason_is_stop?("stop"), do: true
  defp finish_reason_is_stop?(_), do: false

  defp tool_call_chunk?(%StreamChunk{type: :tool_call}), do: true
  defp tool_call_chunk?(_), do: false

  # Propagate response_id from metadata to message metadata for multi-turn
  defp propagate_response_id(response, %{response_id: id}) when is_binary(id) do
    update_in(response.message.metadata, fn meta ->
      Map.put(meta || %{}, :response_id, id)
    end)
  end

  defp propagate_response_id(response, _metadata), do: response
end
