defmodule ReqLLM.Providers.Google.ResponseBuilder do
  @moduledoc """
  Google/Gemini-specific ResponseBuilder implementation.

  Handles Google's specific requirements:
  - Detects `functionCall` in parts to set correct finish_reason
  - Google returns "STOP" even when function calls are made
  - Extracts reasoning_details with thought signatures from thinking chunks
  - Preserves text thought signatures and their original part boundaries

  This fixes bug #271 where streaming responses with tool calls
  had `:stop` finish_reason instead of `:tool_calls`.
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder
  alias ReqLLM.StreamChunk

  @impl true
  def build_response(chunks, metadata, opts) do
    has_tool_calls? = Enum.any?(chunks, &tool_call_chunk?/1)

    metadata =
      if has_tool_calls? and finish_reason_is_stop?(metadata[:finish_reason]) do
        Map.put(metadata, :finish_reason, :tool_calls)
      else
        metadata
      end

    with {:ok, response} <-
           DefaultBuilder.build_response(preserve_signed_text_parts(chunks), metadata, opts) do
      reasoning_details = extract_google_reasoning_details(chunks)
      response_with_reasoning = attach_reasoning_details(response, reasoning_details)
      {:ok, response_with_reasoning}
    end
  end

  defp preserve_signed_text_parts(chunks) do
    Enum.map(chunks, fn
      %StreamChunk{type: :content, text: text, metadata: %{thought_signature: signature}}
      when is_binary(signature) and signature != "" ->
        StreamChunk.content_part(%ReqLLM.Message.ContentPart{
          type: :text,
          text: text,
          metadata: %{thought_signature: signature}
        })

      chunk ->
        chunk
    end)
  end

  defp finish_reason_is_stop?(:stop), do: true
  defp finish_reason_is_stop?("stop"), do: true
  defp finish_reason_is_stop?(_), do: false

  defp tool_call_chunk?(%StreamChunk{type: :tool_call}), do: true
  defp tool_call_chunk?(_), do: false

  defp extract_google_reasoning_details(chunks) do
    chunks
    |> Enum.filter(&thinking_chunk?/1)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %ReqLLM.Message.ReasoningDetails{
        text: chunk.text,
        signature: Map.get(chunk.metadata, :signature),
        encrypted?: Map.get(chunk.metadata, :signature) != nil,
        provider: :google,
        format: "google-gemini-v1",
        index: index,
        provider_data: %{"thought" => true}
      }
    end)
  end

  defp thinking_chunk?(%StreamChunk{type: :thinking}), do: true
  defp thinking_chunk?(_), do: false

  defp attach_reasoning_details(response, []), do: response

  defp attach_reasoning_details(%{message: nil} = response, _details), do: response

  defp attach_reasoning_details(%{message: message} = response, details) do
    updated_message = %{message | reasoning_details: details}

    updated_context =
      case response.context.messages do
        [] ->
          %{response.context | messages: [updated_message]}

        msgs ->
          {init, [last]} = Enum.split(msgs, -1)

          if is_struct(last, ReqLLM.Message) and last.role == message.role do
            updated_last = %{last | reasoning_details: details}
            %{response.context | messages: init ++ [updated_last]}
          else
            response.context
          end
      end

    %{response | message: updated_message, context: updated_context}
  end
end
