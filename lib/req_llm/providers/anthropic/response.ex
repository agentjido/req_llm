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

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails

  # Server-side tool blocks the API executes on the model's behalf and expects
  # back VERBATIM, IN PLACE, in the next assistant turn. Tool search
  # (`server_tool_use` + `tool_search_tool_result`) is the case that bites:
  # they arrive mid-turn, so a thinking block can follow them, and the encoder
  # hoists thinking blocks to the front. Measured against the live API on a
  # turn shaped `thinking · text · server_tool_use · … · thinking · tool_use`:
  # replaying it unchanged is accepted; hoisting the second thinking block is
  # rejected with "`thinking` … blocks in the latest assistant message cannot
  # be modified".
  #
  # So the blocks are decoded as `ContentPart.provider_block/3`, which
  # `Anthropic.Context` replays unchanged at its position — and a thinking
  # block that FOLLOWS one is decoded the same way instead of as a reasoning
  # detail, because only the ordered content keeps its place. Thinking before
  # the first server block keeps the reasoning-detail path, so a turn without
  # server tools decodes and encodes exactly as it did before.
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
    chunks = content_chunks ++ reasoning_detail_chunks(extract_reasoning_details(content_chunks))

    metadata = %{
      response_id: id,
      response_model: model_name,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: Map.drop(data, ["id", "model", "content", "usage", "stop_reason"])
    }

    ReqLLM.Providers.Anthropic.ResponseBuilder.build_buffered_response(
      chunks,
      metadata,
      context: %ReqLLM.Context{messages: []},
      model: model
    )
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
        finish_reason = parse_finish_reason(Map.get(delta, "stop_reason")) || :unknown

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
    %{
      thinking_blocks: %{},
      next_reasoning_index: 0,
      server_tool_blocks: %{},
      raw_thinking_blocks: %{},
      after_server_tool?: false
    }
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
        cond do
          Map.has_key?(state.server_tool_blocks, index) ->
            finalize_server_tool_block(index, state)

          Map.has_key?(state.raw_thinking_blocks, index) ->
            finalize_raw_thinking_block(index, state)

          true ->
            finalize_thinking_block(index, state)
        end

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
    {server_tool_chunks, state} = drain_server_tool_blocks(state)
    {reasoning_detail_chunks(details) ++ server_tool_chunks, state}
  end

  # Private helper functions

  defp decode_content([]), do: []

  defp decode_content(content) when is_list(content) do
    content
    |> Enum.map_reduce(false, fn block, after_server_tool? ->
      {decode_content_block(block, after_server_tool?),
       after_server_tool? or server_tool_block?(block)}
    end)
    |> elem(0)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp decode_content(content) when is_binary(content) do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp server_tool_block?(%{"type" => "server_tool_use"}), do: true
  defp server_tool_block?(%{"type" => "redacted_thinking"}), do: true
  defp server_tool_block?(block), do: server_tool_result?(block)

  defp server_tool_result?(%{"type" => type}) when is_binary(type),
    do: String.ends_with?(type, "_tool_result")

  defp server_tool_result?(_block), do: false

  # A thinking block after a server tool block must keep its position, so it is
  # carried as a provider block rather than a reasoning detail.
  defp decode_content_block(%{"type" => "thinking"} = block, true),
    do: server_tool_block_chunk(block)

  defp decode_content_block(block, _after_server_tool?), do: decode_content_block(block)

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

  defp decode_content_block(%{"type" => _type} = block) do
    if server_tool_block?(block), do: server_tool_block_chunk(block)
  end

  defp decode_content_block(_), do: nil

  defp server_tool_block_chunk(block) do
    ReqLLM.StreamChunk.content_part(ContentPart.provider_block(:anthropic, block))
  end

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

  defp decode_content_block_delta(delta, index, %{raw_thinking_blocks: raw} = state)
       when is_map_key(raw, index) do
    chunks =
      case delta do
        %{"type" => "thinking_delta"} ->
          raw_thinking_stream_chunks(delta["thinking"] || delta["text"])

        _ ->
          []
      end

    {chunks, update_in(state, [:raw_thinking_blocks, index], &merge_thinking_delta(&1, delta))}
  end

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

  defp decode_content_block_delta(
         %{"type" => "input_json_delta", "partial_json" => fragment},
         index,
         %{server_tool_blocks: blocks} = state
       )
       when is_binary(fragment) and is_map_key(blocks, index) do
    state =
      update_in(state, [:server_tool_blocks, index, :fragments], &[fragment | &1])

    {[], state}
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

  defp decode_content_block_start(%{"type" => _type} = block, _index) do
    if server_tool_block?(block), do: [server_tool_block_chunk(block)], else: []
  end

  defp decode_content_block_start(_, _index), do: []

  # `server_tool_use` streams its `input` as `input_json_delta` fragments, so the
  # block is held in state and emitted whole at `content_block_stop`. The result
  # block arrives complete in `content_block_start`.
  defp decode_content_block_start(%{"type" => "server_tool_use"} = block, index, state) do
    {[], put_in(state, [:server_tool_blocks, index], %{block: block, fragments: []})}
  end

  defp decode_content_block_start(
         %{"type" => "thinking"} = block,
         index,
         %{after_server_tool?: true} = state
       ) do
    {raw_thinking_stream_chunks(extract_thinking_text(block), block),
     put_in(state, [:raw_thinking_blocks, index], block)}
  end

  defp decode_content_block_start(%{"type" => "thinking"} = block, index, state) do
    text = extract_thinking_text(block)

    chunks =
      if text == "", do: [], else: [ReqLLM.StreamChunk.thinking(text, thinking_metadata(block))]

    {chunks, start_thinking_block(state, index, block)}
  end

  defp decode_content_block_start(block, index, state) do
    if server_tool_block?(block) do
      {[server_tool_block_chunk(block)], %{state | after_server_tool?: true}}
    else
      {decode_content_block_start(block, index), state}
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

  defp parse_usage(usage) when is_map(usage) and map_size(usage) > 0 do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    cache_read = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation = Map.get(usage, "cache_creation_input_tokens", 0)

    reasoning_tokens =
      get_in(usage, ["output_tokens_details", "thinking_tokens"]) ||
        Map.get(usage, "reasoning_output_tokens", 0)

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

    base =
      case Map.get(usage, "cache_creation") do
        %{} = groups -> Map.put(base, :cache_creation, groups)
        _ -> base
      end

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

    tool_search = Map.get(server_tool_use, "tool_search_requests")

    %{}
    |> maybe_put_tool_usage(:web_search, web_search)
    |> maybe_put_tool_usage(:web_fetch, web_fetch)
    |> maybe_put_tool_usage(:tool_search, tool_search)
  end

  defp maybe_put_tool_usage(tool_usage, tool, count) when is_number(count) and count > 0 do
    Map.merge(tool_usage, ReqLLM.Usage.Tool.build(tool, count))
  end

  defp maybe_put_tool_usage(tool_usage, _tool, _count), do: tool_usage

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("end_turn"), do: :stop
  defp parse_finish_reason("stop_sequence"), do: :stop
  defp parse_finish_reason("max_tokens"), do: :length
  defp parse_finish_reason("model_context_window_exceeded"), do: :length
  defp parse_finish_reason("tool_use"), do: :tool_calls
  defp parse_finish_reason("pause_turn"), do: :incomplete
  defp parse_finish_reason("refusal"), do: :content_filter
  defp parse_finish_reason("content_filter"), do: :content_filter
  defp parse_finish_reason(reason) when is_binary(reason), do: :unknown
  defp parse_finish_reason(_), do: nil

  defp ensure_stream_state(nil), do: init_stream_state()

  defp ensure_stream_state(state) do
    state
    |> Map.put_new(:server_tool_blocks, %{})
    |> Map.put_new(:raw_thinking_blocks, %{})
    |> Map.put_new(:after_server_tool?, false)
  end

  # `message_start` carries the message id and the served model. Surfacing them
  # as metadata lets the response builder keep the provider id on streamed
  # responses instead of generating a local one.
  defp message_start_chunks(message) do
    meta =
      %{}
      |> maybe_put_meta(:response_id, Map.get(message, "id"))
      |> maybe_put_meta(:response_model, Map.get(message, "model"))

    case Map.get(message, "usage", %{}) do
      usage_data when usage_data == %{} -> []
      usage_data -> [ReqLLM.StreamChunk.meta(Map.put(meta, :usage, parse_usage(usage_data)))]
    end
    |> case do
      [] when meta == %{} -> []
      [] -> [ReqLLM.StreamChunk.meta(meta)]
      chunks -> chunks
    end
  end

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value) when is_binary(value), do: Map.put(meta, key, value)
  defp maybe_put_meta(meta, _key, _value), do: meta

  defp message_delta_chunks(data, delta) do
    finish_reason = parse_finish_reason(Map.get(delta, "stop_reason")) || :unknown

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

  defp finalize_server_tool_block(index, %{server_tool_blocks: blocks} = state) do
    {entry, remaining} = Map.pop(blocks, index)

    {[server_tool_block_chunk(complete_server_tool_block(entry))],
     %{state | server_tool_blocks: remaining, after_server_tool?: true}}
  end

  defp finalize_raw_thinking_block(index, %{raw_thinking_blocks: blocks} = state) do
    {block, remaining} = Map.pop(blocks, index)
    {[server_tool_block_chunk(block)], %{state | raw_thinking_blocks: remaining}}
  end

  defp merge_thinking_delta(block, %{"type" => "thinking_delta"} = delta) do
    text = delta["thinking"] || delta["text"] || ""
    Map.update(block, "thinking", text, &((&1 || "") <> text))
  end

  defp merge_thinking_delta(block, %{"type" => "signature_delta", "signature" => signature}),
    do: Map.put(block, "signature", signature)

  defp merge_thinking_delta(block, _delta), do: block

  defp raw_thinking_stream_chunks(text, block \\ %{})

  defp raw_thinking_stream_chunks(text, block) when is_binary(text) and text != "" do
    [ReqLLM.StreamChunk.thinking(text, Map.put(thinking_metadata(block), :stream_only?, true))]
  end

  defp raw_thinking_stream_chunks(_text, _block), do: []

  defp drain_server_tool_blocks(%{server_tool_blocks: blocks, raw_thinking_blocks: raw} = state) do
    chunks =
      Enum.map(blocks, fn {index, entry} -> {index, complete_server_tool_block(entry)} end)
      |> Enum.concat(Map.to_list(raw))
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_, block} -> server_tool_block_chunk(block) end)

    {chunks, %{state | server_tool_blocks: %{}, raw_thinking_blocks: %{}}}
  end

  # The streamed `input` (`{}` at start) is replaced by the decoded fragments;
  # an undecodable or empty fragment stream keeps whatever the start block had.
  defp complete_server_tool_block(%{block: block, fragments: fragments}) do
    case fragments |> Enum.reverse() |> IO.iodata_to_binary() do
      "" ->
        block

      json ->
        case Jason.decode(json) do
          {:ok, input} when is_map(input) -> Map.put(block, "input", input)
          _ -> block
        end
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
