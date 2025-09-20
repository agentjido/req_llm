defmodule ReqLLM.Providers.Anthropic.Response do
  @moduledoc """
  Anthropic-specific response decoding for the Messages API format.

  Handles decoding Anthropic Messages API responses to ReqLLM structures.

  ## Anthropic Response Format

      %{
        "id" => "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [
          %{"type" => "text", "text" => "Hello! How can I help you today?"}
        ],
        "stop_reason" => "stop",
        "stop_sequence" => nil,
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

  ## Streaming Format

  Anthropic uses Server-Sent Events (SSE) with different event types:
  - message_start: Initial message metadata
  - content_block_start: Start of content block
  - content_block_delta: Incremental content
  - content_block_stop: End of content block
  - message_delta: Final message updates
  - message_stop: End of message

  """

  @doc """
  Decode Anthropic response data to ReqLLM.Response.
  """
  @spec decode_response(map(), ReqLLM.Model.t()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
  def decode_response(data, model) when is_map(data) do
    id = Map.get(data, "id", "unknown")
    model_name = Map.get(data, "model", model.model || "unknown")
    usage = parse_usage(Map.get(data, "usage"))

    finish_reason = parse_finish_reason(Map.get(data, "stop_reason"))

    content_chunks = decode_content(Map.get(data, "content", []))
    message = build_message_from_chunks(content_chunks)

    context = %ReqLLM.Context{
      messages: if(message, do: [message], else: [])
    }

    response = %ReqLLM.Response{
      id: id,
      model: model_name,
      context: context,
      message: message,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: Map.drop(data, ["id", "model", "content", "usage", "stop_reason"])
    }

    {:ok, response}
  end

  def decode_response(_data, _model) do
    {:error, :not_implemented}
  end

  @doc """
  Decode Anthropic SSE event data into StreamChunks.
  """
  @spec decode_sse_event(map(), ReqLLM.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def decode_sse_event(%{data: data}, _model) when is_map(data) do
    case data do
      %{"type" => "content_block_delta", "delta" => delta} ->
        decode_content_delta(delta)

      %{"type" => "content_block_start", "content_block" => block} ->
        decode_content_block_start(block)

      _ ->
        []
    end
  end

  def decode_sse_event(_, _model), do: []

  # Private helper functions

  defp decode_content([]), do: []

  defp decode_content(content) when is_list(content) do
    content
    |> Enum.map(&decode_content_block/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp decode_content(content) when is_binary(content) do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_content_block(%{"type" => "text", "text" => text}) do
    ReqLLM.StreamChunk.text(text)
  end

  defp decode_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    ReqLLM.StreamChunk.tool_call(name, input, %{id: id})
  end

  defp decode_content_block(_), do: nil

  defp decode_content_delta(%{"type" => "text_delta", "text" => text}) when is_binary(text) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_delta(%{
         "type" => "tool_call_delta",
         "id" => id,
         "name" => name,
         "partial_json" => json_fragment
       }) do
    # Anthropic sends partial JSON that needs to be accumulated
    # For now, we'll create a tool call chunk with partial data
    args =
      case Jason.decode(json_fragment || "{}") do
        {:ok, parsed} -> parsed
        {:error, _} -> %{partial: json_fragment}
      end

    [ReqLLM.StreamChunk.tool_call(name, args, %{id: id, partial: true})]
  end

  defp decode_content_delta(_), do: []

  defp decode_content_block_start(%{"type" => "text", "text" => text}) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_block_start(%{"type" => "tool_use", "id" => id, "name" => name}) do
    # Tool call start - send empty arguments that will be filled by deltas
    [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, start: true})]
  end

  defp decode_content_block_start(_), do: []

  defp build_message_from_chunks([]), do: nil

  defp build_message_from_chunks(chunks) do
    content_parts =
      chunks
      |> Enum.map(&chunk_to_content_part/1)
      |> Enum.reject(&is_nil/1)

    if content_parts != [] do
      %ReqLLM.Message{
        role: :assistant,
        content: content_parts,
        metadata: %{}
      }
    end
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{type: :content, text: text}) do
    %ReqLLM.Message.ContentPart{type: :text, text: text}
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{
         type: :tool_call,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    %ReqLLM.Message.ContentPart{
      type: :tool_call,
      tool_name: name,
      input: args,
      tool_call_id: Map.get(meta, :id)
    }
  end

  defp chunk_to_content_part(_), do: nil

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output}) do
    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output
    }
  end

  defp parse_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("max_tokens"), do: :length
  defp parse_finish_reason("tool_use"), do: :tool_calls
  defp parse_finish_reason("end_turn"), do: :stop
  defp parse_finish_reason(reason) when is_binary(reason), do: reason
  defp parse_finish_reason(_), do: nil
end
