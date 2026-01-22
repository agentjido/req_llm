defmodule ReqLLM.Providers.Google.ResponseBuilder do
  @moduledoc """
  Google/Gemini-specific ResponseBuilder implementation.

  Handles Google's specific requirements:
  - Detects `functionCall` in parts to set correct finish_reason
  - Google returns "STOP" even when function calls are made

  This fixes bug #271 where streaming responses with tool calls
  had `:stop` finish_reason instead of `:tool_calls`.
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder
  alias ReqLLM.StreamChunk

  @impl true
  def build_response(chunks, metadata, opts) do
    # Check if any chunks are tool calls
    has_tool_calls? = Enum.any?(chunks, &tool_call_chunk?/1)

    # Override finish_reason if we have tool calls but finish_reason is :stop
    # Google returns "STOP" which may be normalized to "stop" (string) or :stop (atom)
    metadata =
      if has_tool_calls? and finish_reason_is_stop?(metadata[:finish_reason]) do
        Map.put(metadata, :finish_reason, :tool_calls)
      else
        metadata
      end

    # Build response using default implementation with corrected metadata
    DefaultBuilder.build_response(chunks, metadata, opts)
  end

  defp finish_reason_is_stop?(:stop), do: true
  defp finish_reason_is_stop?("stop"), do: true
  defp finish_reason_is_stop?(_), do: false

  defp tool_call_chunk?(%StreamChunk{type: :tool_call}), do: true
  defp tool_call_chunk?(_), do: false
end
