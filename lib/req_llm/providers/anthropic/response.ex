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

  alias ReqLLM.Message.ReasoningDetails

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

        raw_usage = Map.get(data, "usage", %{})

        chunks = [ReqLLM.StreamChunk.meta(%{finish_reason: finish_reason, terminal?: true})]

        # Add usage chunk if present
        if raw_usage == %{} do
          chunks
        else
          usage_chunk = ReqLLM.StreamChunk.meta(%{usage: parse_usage(raw_usage)})
          [usage_chunk | chunks]
        end

      %{"type" => "ping"} ->
        [ReqLLM.StreamChunk.meta(%{keepalive?: true, provider_event: :ping})]

      _ ->
        []
    end
  end

  def decode_stream_event(_, _model), do: []

  @doc false
  def init_stream_state do
    %{thinking_blocks: %{}, next_reasoning_index: 0}
  end

  @doc false
  @spec decode_stream_event(map(), LLMDB.Model.t(), map() | nil) ::
          {[ReqLLM.StreamChunk.t()], map()}
  def decode_stream_event(%{data: data}, _model, state) when is_map(data) do
    state = ensure_stream_state(state)

    case data do
      %{"type" => "message_start", "message" => message} ->
        {message_start_chunks(message), state}

      %{"type" => "content_block_delta", "index" => index, "delta" => delta} ->
        decode_content_block_delta(delta, index, state)

      %{"type" => "content_block_start", "index" => index, "content_block" => block} ->
        decode_content_block_start(block, index, state)

      %{"type" => "content_block_stop", "index" => index} ->
        finalize_thinking_block(index, state)

      %{"type" => "message_stop"} ->
        {[ReqLLM.StreamChunk.meta(%{terminal?: true})], state}

      %{"type" => "message_delta", "delta" => delta} ->
        {message_delta_chunks(data, delta), state}

      %{"type" => "ping"} ->
        {[ReqLLM.StreamChunk.meta(%{keepalive?: true, provider_event: :ping})], state}

      _ ->
        {[], state}
    end
  end

  def decode_stream_event(_event, _model, state) do
    {[], ensure_stream_state(state)}
  end

  @doc false
  @spec flush_stream_state(LLMDB.Model.t(), map() | nil) :: {[ReqLLM.StreamChunk.t()], map()}
  def flush_stream_state(_model, state) do
    state = ensure_stream_state(state)
    {details, state} = drain_thinking_blocks(state)
    {reasoning_detail_chunks(details), state}
  end

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

  defp decode_content_block(%{"type" => "thinking", "thinking" => text} = block) do
    ReqLLM.StreamChunk.thinking(text, thinking_metadata(block))
  end

  defp decode_content_block(%{"type" => "thinking", "text" => text} = block) do
    ReqLLM.StreamChunk.thinking(text, thinking_metadata(block))
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
    [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
  end

  defp decode_content_block_delta(%{"type" => "thinking_delta", "text" => text}, _index)
       when is_binary(text) do
    [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
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

  defp decode_content_block_delta(%{"type" => "thinking_delta", "thinking" => text}, index, state)
       when is_binary(text) do
    chunks = if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
    {chunks, append_thinking_text(state, index, text)}
  end

  defp decode_content_block_delta(%{"type" => "thinking_delta", "text" => text}, index, state)
       when is_binary(text) do
    chunks = if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
    {chunks, append_thinking_text(state, index, text)}
  end

  defp decode_content_block_delta(
         %{"type" => "signature_delta", "signature" => signature},
         index,
         state
       )
       when is_binary(signature) do
    {[], update_thinking_signature(state, index, signature)}
  end

  defp decode_content_block_delta(delta, index, state) do
    {decode_content_block_delta(delta, index), state}
  end

  defp decode_content_block_start(%{"type" => "text", "text" => text}, _index) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_block_start(%{"type" => "thinking", "thinking" => text}, _index) do
    [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
  end

  defp decode_content_block_start(%{"type" => "thinking", "text" => text}, _index) do
    [ReqLLM.StreamChunk.thinking(text, thinking_metadata())]
  end

  defp decode_content_block_start(%{"type" => "tool_use", "id" => id, "name" => name}, index) do
    # Tool call start - send empty arguments that will be filled by deltas
    [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: index, start: true})]
  end

  defp decode_content_block_start(_, _index), do: []

  defp decode_content_block_start(%{"type" => "thinking"} = block, index, state) do
    text = extract_thinking_text(block)

    chunks =
      if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text, thinking_metadata(block))]

    {chunks, start_thinking_block(state, index, block)}
  end

  defp decode_content_block_start(block, index, state) do
    {decode_content_block_start(block, index), state}
  end

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

    reasoning_details = extract_reasoning_details(chunks)

    if content_parts != [] or tool_calls != [] do
      %ReqLLM.Message{
        role: :assistant,
        content: content_parts,
        tool_calls: if(tool_calls != [], do: tool_calls),
        reasoning_details: if(reasoning_details != [], do: reasoning_details),
        metadata: %{}
      }
    end
  end

  defp extract_reasoning_details(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :thinking))
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      sig = Map.get(chunk.metadata, :signature)

      %ReqLLM.Message.ReasoningDetails{
        text: chunk.text,
        signature: sig,
        encrypted?: sig != nil,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: index,
        provider_data: %{"type" => "thinking"}
      }
    end)
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

  defp parse_usage(usage) when is_map(usage) and map_size(usage) > 0 do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    cache_read = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation = Map.get(usage, "cache_creation_input_tokens", 0)
    reasoning_tokens = Map.get(usage, "reasoning_output_tokens", 0)
    tool_usage = anthropic_tool_usage(usage)

    base = %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cached_tokens: cache_read,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_creation,
      reasoning_tokens: reasoning_tokens
    }

    if map_size(tool_usage) > 0 do
      Map.put(base, :tool_usage, tool_usage)
    else
      base
    end
  end

  defp parse_usage(_),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0
    }

  defp anthropic_tool_usage(usage) when is_map(usage) do
    server_tool_use = Map.get(usage, "server_tool_use", %{})

    web_search = Map.get(server_tool_use, "web_search_requests")

    web_fetch = Map.get(server_tool_use, "web_fetch_requests")

    %{}
    |> maybe_put_tool_usage(:web_search, web_search)
    |> maybe_put_tool_usage(:web_fetch, web_fetch)
  end

  defp maybe_put_tool_usage(tool_usage, tool, count) when is_number(count) and count > 0 do
    Map.merge(tool_usage, ReqLLM.Usage.Tool.build(tool, count))
  end

  defp maybe_put_tool_usage(tool_usage, _tool, _count), do: tool_usage

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("max_tokens"), do: :length
  defp parse_finish_reason("tool_use"), do: :tool_calls
  defp parse_finish_reason("end_turn"), do: :stop
  defp parse_finish_reason("content_filter"), do: :content_filter
  defp parse_finish_reason(reason) when is_binary(reason), do: :error
  defp parse_finish_reason(_), do: nil

  defp ensure_stream_state(nil), do: init_stream_state()
  defp ensure_stream_state(state), do: state

  defp message_start_chunks(message) do
    usage_data = Map.get(message, "usage", %{})

    if usage_data == %{} do
      []
    else
      usage = parse_usage(usage_data)
      [ReqLLM.StreamChunk.meta(%{usage: usage})]
    end
  end

  defp message_delta_chunks(data, delta) do
    finish_reason =
      case Map.get(delta, "stop_reason") do
        "end_turn" -> :stop
        "max_tokens" -> :length
        "stop_sequence" -> :stop
        "tool_use" -> :tool_calls
        _ -> :unknown
      end

    raw_usage = Map.get(data, "usage", %{})
    chunks = [ReqLLM.StreamChunk.meta(%{finish_reason: finish_reason, terminal?: true})]

    if raw_usage == %{} do
      chunks
    else
      usage_chunk = ReqLLM.StreamChunk.meta(%{usage: parse_usage(raw_usage)})
      [usage_chunk | chunks]
    end
  end

  defp start_thinking_block(state, index, block) do
    text = extract_thinking_text(block)
    signature = normalize_signature(Map.get(block, "signature"))

    update_thinking_block(state, index, fn thinking_block ->
      %{
        thinking_block
        | text: thinking_block.text <> text,
          signature: signature || thinking_block.signature
      }
    end)
  end

  defp append_thinking_text(state, index, text) do
    update_thinking_block(state, index, fn thinking_block ->
      %{thinking_block | text: thinking_block.text <> text}
    end)
  end

  defp update_thinking_signature(state, index, signature) do
    normalized_signature = normalize_signature(signature)

    update_thinking_block(state, index, fn thinking_block ->
      %{thinking_block | signature: normalized_signature || thinking_block.signature}
    end)
  end

  defp update_thinking_block(state, index, fun) do
    {thinking_block, state} = fetch_thinking_block(state, index)
    updated_block = fun.(thinking_block)
    %{state | thinking_blocks: Map.put(state.thinking_blocks, index, updated_block)}
  end

  defp fetch_thinking_block(%{thinking_blocks: thinking_blocks} = state, index) do
    case Map.fetch(thinking_blocks, index) do
      {:ok, thinking_block} ->
        {thinking_block, state}

      :error ->
        thinking_block = %{text: "", signature: nil, reasoning_index: state.next_reasoning_index}
        {thinking_block, %{state | next_reasoning_index: state.next_reasoning_index + 1}}
    end
  end

  defp finalize_thinking_block(index, %{thinking_blocks: thinking_blocks} = state) do
    case Map.pop(thinking_blocks, index) do
      {nil, _remaining_blocks} ->
        {[], state}

      {thinking_block, remaining_blocks} ->
        detail = build_reasoning_detail(thinking_block)
        chunk = ReqLLM.StreamChunk.meta(%{reasoning_details: [detail]})
        {[chunk], %{state | thinking_blocks: remaining_blocks}}
    end
  end

  defp drain_thinking_blocks(%{thinking_blocks: thinking_blocks} = state) do
    details =
      thinking_blocks
      |> Map.values()
      |> Enum.sort_by(& &1.reasoning_index)
      |> Enum.map(&build_reasoning_detail/1)

    {details, %{state | thinking_blocks: %{}}}
  end

  defp reasoning_detail_chunks([]), do: []

  defp reasoning_detail_chunks(details),
    do: [ReqLLM.StreamChunk.meta(%{reasoning_details: details})]

  defp build_reasoning_detail(thinking_block) do
    signature = normalize_signature(thinking_block.signature)

    %ReasoningDetails{
      text: thinking_block.text,
      signature: signature,
      encrypted?: signature != nil,
      provider: :anthropic,
      format: "anthropic-thinking-v1",
      index: thinking_block.reasoning_index,
      provider_data: %{"type" => "thinking"}
    }
  end

  defp extract_thinking_text(block) do
    cond do
      is_binary(block["thinking"]) -> block["thinking"]
      is_binary(block["text"]) -> block["text"]
      true -> ""
    end
  end

  defp thinking_metadata(block \\ %{}) do
    signature = normalize_signature(Map.get(block, "signature"))

    %{
      signature: signature,
      encrypted?: signature != nil,
      provider: :anthropic,
      format: "anthropic-thinking-v1",
      provider_data: %{"type" => "thinking"}
    }
  end

  defp normalize_signature(signature) when is_binary(signature) do
    if signature == "", do: nil, else: signature
  end

  defp normalize_signature(_signature), do: nil
end
