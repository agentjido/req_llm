defmodule ReqLLM.Providers.Anthropic.Response do
  @moduledoc """
  Anthropic-specific response decoding for the Messages API format.

  Handles decoding Anthropic Messages API responses to ReqLLM structures.

  ## Anthropic Response Format

      %{
        "id" => "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
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
  @spec decode_response(map(), LLMDB.Model.t()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
  def decode_response(data, model) when is_map(data) do
    id = Map.get(data, "id", "unknown")
    model_name = Map.get(data, "model", model.id || "unknown")
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
  @spec decode_stream_event(map(), LLMDB.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def decode_stream_event(%{data: data}, _model) when is_map(data) do
    case data do
      %{"type" => "message_start", "message" => message} ->
        usage_data = Map.get(message, "usage", %{})

        if usage_data == %{} do
          []
        else
          usage = parse_usage(usage_data)
          [ReqLLM.StreamChunk.meta(%{usage: usage})]
        end

      %{"type" => "content_block_delta", "index" => index, "delta" => delta} ->
        decode_content_block_delta(delta, index)

      %{"type" => "content_block_start", "index" => index, "content_block" => block} ->
        decode_content_block_start(block, index)

      # Terminal events with metadata
      %{"type" => "message_stop"} ->
        [ReqLLM.StreamChunk.meta(%{terminal?: true})]

      %{"type" => "message_delta", "delta" => delta} ->
        finish_reason =
          case Map.get(delta, "stop_reason") do
            "end_turn" -> :stop
            "max_tokens" -> :length
            "stop_sequence" -> :stop
            "tool_use" -> :tool_calls
            _ -> :unknown
          end

        usage = Map.get(data, "usage", %{})

        chunks = [ReqLLM.StreamChunk.meta(%{finish_reason: finish_reason, terminal?: true})]

        # Add usage chunk if present
        if usage == %{} do
          chunks
        else
          usage_chunk = ReqLLM.StreamChunk.meta(%{usage: usage})
          [usage_chunk | chunks]
        end

      %{"type" => "ping"} ->
        # Keep-alive ping, no content
        []

      _ ->
        []
    end
  end

  def decode_stream_event(_, _model), do: []

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

  defp decode_content_block(%{"type" => "thinking", "thinking" => text}) do
    ReqLLM.StreamChunk.thinking(text)
  end

  defp decode_content_block(%{"type" => "thinking", "text" => text}) do
    ReqLLM.StreamChunk.thinking(text)
  end

  defp decode_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    ReqLLM.StreamChunk.tool_call(name, input, %{id: id})
  end

  defp decode_content_block(_), do: nil

  defp decode_content_block_delta(%{"type" => "text_delta", "text" => text}, _index)
       when is_binary(text) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_block_delta(%{"type" => "thinking_delta", "thinking" => text}, _index)
       when is_binary(text) do
    [ReqLLM.StreamChunk.thinking(text)]
  end

  defp decode_content_block_delta(%{"type" => "thinking_delta", "text" => text}, _index)
       when is_binary(text) do
    [ReqLLM.StreamChunk.thinking(text)]
  end

  defp decode_content_block_delta(
         %{"type" => "input_json_delta", "partial_json" => fragment},
         index
       )
       when is_binary(fragment) do
    # Accumulate JSON fragments; StreamResponse.extract_tool_calls will merge these
    [ReqLLM.StreamChunk.meta(%{tool_call_args: %{index: index, fragment: fragment}})]
  end

  defp decode_content_block_delta(_, _index), do: []

  defp decode_content_block_start(%{"type" => "text", "text" => text}, _index) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_block_start(%{"type" => "thinking", "thinking" => text}, _index) do
    [ReqLLM.StreamChunk.thinking(text)]
  end

  defp decode_content_block_start(%{"type" => "thinking", "text" => text}, _index) do
    [ReqLLM.StreamChunk.thinking(text)]
  end

  defp decode_content_block_start(%{"type" => "tool_use", "id" => id, "name" => name}, index) do
    # Tool call start - send empty arguments that will be filled by deltas
    [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: index, start: true})]
  end

  defp decode_content_block_start(_, _index), do: []

  defp build_message_from_chunks([]), do: nil

  defp build_message_from_chunks(chunks) do
    content_parts =
      chunks
      |> Enum.filter(&(&1.type in [:content, :thinking]))
      |> Enum.map(&chunk_to_content_part/1)
      |> Enum.reject(&is_nil/1)

    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(&chunk_to_tool_call/1)
      |> Enum.reject(&is_nil/1)

    if content_parts != [] or tool_calls != [] do
      %ReqLLM.Message{
        role: :assistant,
        content: content_parts,
        tool_calls: if(tool_calls != [], do: tool_calls),
        metadata: %{}
      }
    end
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{type: :content, text: text}) do
    %ReqLLM.Message.ContentPart{type: :text, text: text}
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{type: :thinking, text: text}) do
    %ReqLLM.Message.ContentPart{type: :thinking, text: text}
  end

  defp chunk_to_content_part(_), do: nil

  defp chunk_to_tool_call(%ReqLLM.StreamChunk{
         type: :tool_call,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    args_json = if is_binary(args), do: args, else: Jason.encode!(args)
    id = Map.get(meta, :id)
    ReqLLM.ToolCall.new(id, name, args_json)
  end

  defp chunk_to_tool_call(_), do: nil

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    cache_read = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation = Map.get(usage, "cache_creation_input_tokens", 0)
    reasoning_tokens = Map.get(usage, "reasoning_output_tokens", 0)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cached_tokens: cache_read,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_creation,
      reasoning_tokens: reasoning_tokens
    }
  end

  defp parse_usage(_),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0
    }

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("max_tokens"), do: :length
  defp parse_finish_reason("tool_use"), do: :tool_calls
  defp parse_finish_reason("end_turn"), do: :stop
  defp parse_finish_reason("content_filter"), do: :content_filter
  defp parse_finish_reason(reason) when is_binary(reason), do: :error
  defp parse_finish_reason(_), do: nil
end
