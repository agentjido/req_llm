defmodule ReqLLM.StreamResponse.EventProjector do
  @moduledoc false

  alias ReqLLM.Provider.ChunkAccumulator
  alias ReqLLM.Response.OutputItem
  alias ReqLLM.Response.Projection
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamEvent
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  @canonical_meta_keys [
    :annotation,
    "annotation",
    :annotations,
    "annotations",
    :citation,
    "citation",
    :citations,
    "citations",
    :code_interpreter_item,
    "code_interpreter_item",
    :error,
    "error",
    :file,
    "file",
    :files,
    "files",
    :finish_reason,
    "finish_reason",
    :output_item,
    "output_item",
    :output_items,
    "output_items",
    :provider_meta,
    "provider_meta",
    :provider_item,
    "provider_item",
    :provider_items,
    "provider_items",
    :reasoning_details,
    "reasoning_details",
    :refusal,
    "refusal",
    :refusals,
    "refusals",
    :source,
    "source",
    :sources,
    "sources",
    :terminal?,
    "terminal?",
    :tool_call_args,
    "tool_call_args",
    :tool_result,
    "tool_result",
    :tool_results,
    "tool_results",
    :usage,
    "usage",
    :warning,
    "warning",
    :warnings,
    "warnings"
  ]

  @terminal_metadata_keys [
    :model,
    "model",
    :provider,
    "provider",
    :provider_meta,
    "provider_meta",
    :request_id,
    "request_id",
    :response_id,
    "response_id",
    :status,
    "status"
  ]

  @spec events(StreamResponse.t()) :: Enumerable.t()
  def events(%StreamResponse{} = response) do
    Stream.resource(
      fn -> initial_state(response) end,
      &next_events/1,
      &halt_iterator/1
    )
  end

  defp initial_state(response) do
    %{
      accumulator: ChunkAccumulator.new(),
      emitted_items: MapSet.new(),
      error: nil,
      finish_reason: nil,
      iterator: {:enumerable, response.stream},
      metadata_handle: response.metadata_handle,
      model: response.model,
      started?: false,
      terminal_metadata: %{},
      terminal?: false,
      usage: nil,
      warning_sources: [],
      warnings: []
    }
  end

  defp next_events(%{terminal?: true} = state), do: {:halt, state}

  defp next_events(state) do
    case pull(state.iterator) do
      {:ok, %StreamChunk{} = chunk, iterator} ->
        {chunk, state} = prepare_chunk(chunk, %{state | iterator: iterator})
        accumulator = ChunkAccumulator.push(state.accumulator, chunk)
        state = state |> Map.put(:accumulator, accumulator) |> collect_chunk_metadata(chunk)
        {events, state} = chunk_events(chunk, state)
        emit_or_continue(events, state)

      {:ok, value, iterator} ->
        event = StreamEvent.new(:provider_event, Projection.safe_metadata(value))
        emit([event], %{state | iterator: iterator})

      :done ->
        terminal_events(state)
    end
  rescue
    error ->
      emit_terminal_error(error, state)
  catch
    :exit, reason ->
      emit_terminal_error(reason, state)
  end

  defp emit_or_continue([], state), do: next_events(state)
  defp emit_or_continue(events, state), do: emit(events, state)

  defp emit(events, %{started?: false} = state) do
    {[start_event(state.model) | events], %{state | started?: true}}
  end

  defp emit(events, state), do: {events, state}

  defp prepare_chunk(%StreamChunk{type: :tool_call} = chunk, state) do
    metadata = chunk.metadata
    id = value(metadata, :id) || "call_#{ReqLLM.ID.uuid7()}"
    index = value(metadata, :index) || 0
    metadata = metadata |> Map.put_new(:id, id) |> Map.put_new(:index, index)
    {%{chunk | metadata: metadata}, state}
  end

  defp prepare_chunk(chunk, state), do: {chunk, state}

  defp chunk_events(%StreamChunk{type: :content, text: text, metadata: metadata}, state)
       when is_binary(text) do
    event = StreamEvent.new(:text_delta, text, safe_map(metadata))
    output_item_events([event], metadata, state)
  end

  defp chunk_events(%StreamChunk{type: :thinking, text: text, metadata: metadata}, state)
       when is_binary(text) do
    event = StreamEvent.new(:reasoning_delta, text, safe_map(metadata))
    output_item_events([event], metadata, state)
  end

  defp chunk_events(%StreamChunk{type: :tool_call, name: name} = chunk, state)
       when is_binary(name) do
    metadata = chunk.metadata

    data = %{
      id: value(metadata, :id),
      index: value(metadata, :index) || 0,
      name: chunk.name,
      arguments: chunk.arguments || %{}
    }

    event = StreamEvent.new(:tool_call_start, data, safe_map(metadata))
    output_item_events([event], metadata, state)
  end

  defp chunk_events(%StreamChunk{type: :meta, metadata: metadata}, state)
       when is_map(metadata) do
    metadata_events(metadata, state)
  end

  defp chunk_events(%StreamChunk{} = chunk, state) do
    data =
      chunk
      |> Map.from_struct()
      |> Projection.safe_metadata()

    {[StreamEvent.new(:provider_event, data)], state}
  end

  defp metadata_events(metadata, state) do
    events = tool_delta_events(metadata) ++ tool_result_events(metadata)
    {events, state} = output_item_events(events, metadata, state)

    provider_data =
      metadata
      |> Map.drop(@canonical_meta_keys ++ @terminal_metadata_keys)
      |> Projection.safe_metadata()

    events =
      if is_map(provider_data) and map_size(provider_data) > 0 do
        events ++ [StreamEvent.new(:provider_event, provider_data)]
      else
        events
      end

    {events, state}
  end

  defp output_item_events(events, metadata, state) do
    items =
      Projection.metadata_output_items(metadata) ++
        Projection.provider_output_items(provider_metadata(metadata)) ++
        direct_output_items(metadata)

    {item_events, state} = unique_output_item_events(items, state)
    {events ++ item_events, state}
  end

  defp unique_output_item_events(items, state) do
    Enum.reduce(items, {[], state}, fn item, {events, state} ->
      fingerprint = {item.type, item.data, item.metadata}

      if MapSet.member?(state.emitted_items, fingerprint) do
        {events, state}
      else
        event = output_item_event(item)
        emitted_items = MapSet.put(state.emitted_items, fingerprint)
        {events ++ [event], %{state | emitted_items: emitted_items}}
      end
    end)
  end

  defp output_item_event(%OutputItem{type: :source} = item),
    do: StreamEvent.new(:source, item)

  defp output_item_event(%OutputItem{type: :file} = item),
    do: StreamEvent.new(:file, item)

  defp output_item_event(%OutputItem{} = item),
    do: StreamEvent.new(:output_item, item)

  defp direct_output_items(metadata) do
    values(metadata, [:file, "file", :files, "files"])
    |> Enum.map(&%OutputItem{type: :file, data: Projection.safe_metadata(&1), metadata: %{}})
    |> Kernel.++(
      values(metadata, [:code_interpreter_item, "code_interpreter_item"])
      |> Enum.map(&%OutputItem{type: :provider_item, data: &1, metadata: %{}})
    )
  end

  defp tool_delta_events(metadata) do
    case value(metadata, :tool_call_args) do
      data when is_map(data) -> [StreamEvent.new(:tool_call_delta, data)]
      _other -> []
    end
  end

  defp tool_result_events(metadata) do
    metadata
    |> values([:tool_result, "tool_result", :tool_results, "tool_results"])
    |> Enum.map(&StreamEvent.new(:tool_result, &1))
  end

  defp terminal_events(state) do
    metadata = await_metadata(state.metadata_handle)
    {item_events, state} = terminal_output_item_events(metadata, state)
    tool_events = terminal_tool_events(state.accumulator)
    usage_events = usage_events(metadata, state)

    warnings =
      state.warnings
      |> merge_warnings(warning_values(metadata))
      |> Projection.redact_warnings(Enum.reverse(state.warning_sources, [metadata]))
      |> Enum.map(&StreamEvent.new(:warning, &1))

    events =
      item_events ++ tool_events ++ usage_events ++ warnings ++ [terminal_event(metadata, state)]

    {events, state} = emit(events, %{state | iterator: :done, terminal?: true})
    {events, state}
  end

  defp terminal_output_item_events(metadata, state) do
    items =
      Projection.metadata_output_items(metadata) ++
        Projection.provider_output_items(provider_metadata(metadata)) ++
        direct_output_items(metadata)

    unique_output_item_events(items, state)
  end

  defp terminal_tool_events(accumulator) do
    accumulator
    |> ChunkAccumulator.finalize_tool_calls_for_response()
    |> Enum.map(&StreamEvent.new(:tool_call, &1))
  end

  defp usage_events(metadata, state) do
    usage =
      value(metadata, :usage) || state.usage ||
        ChunkAccumulator.finalize_usage(state.accumulator)

    if is_map(usage), do: [StreamEvent.new(:usage, usage)], else: []
  end

  defp terminal_event(metadata, state) do
    error = value(metadata, :error) || state.error

    finish_reason =
      metadata
      |> value(:finish_reason)
      |> Kernel.||(state.finish_reason)
      |> Kernel.||(ChunkAccumulator.finalize_finish_reason(state.accumulator))
      |> normalize_finish_reason()

    event_metadata = terminal_metadata(Map.merge(state.terminal_metadata, metadata))

    cond do
      not is_nil(error) ->
        StreamEvent.new(:error, error, event_metadata)

      finish_reason == :cancelled ->
        StreamEvent.new(:cancelled, %{finish_reason: :cancelled}, event_metadata)

      finish_reason == :error ->
        StreamEvent.new(:error, %{finish_reason: :error}, event_metadata)

      true ->
        StreamEvent.new(:finish, %{finish_reason: finish_reason}, event_metadata)
    end
  end

  defp emit_terminal_error(reason, state) do
    event = StreamEvent.new(:error, reason)
    {events, state} = emit([event], %{state | iterator: :done, terminal?: true})
    {events, state}
  end

  defp start_event(model) do
    StreamEvent.new(:start, %{
      model: %{
        id: model.provider_model_id || model.id || model.model,
        provider: model.provider
      }
    })
  end

  defp terminal_metadata(metadata) do
    metadata
    |> Map.take(@terminal_metadata_keys)
    |> Projection.safe_metadata()
  end

  defp await_metadata(handle) do
    MetadataHandle.await(handle)
  end

  defp provider_metadata(metadata) do
    case value(metadata, :provider_meta) do
      provider_meta when is_map(provider_meta) -> provider_meta
      _other -> %{}
    end
  end

  defp collect_chunk_metadata(state, %StreamChunk{metadata: metadata}) do
    warnings = merge_warnings(state.warnings, warning_values(metadata))
    error = value(metadata, :error) || state.error
    finish_reason = value(metadata, :finish_reason) || state.finish_reason
    usage = merge_usage(state.usage, value(metadata, :usage))
    warning_sources = collect_warning_source(state.warning_sources, metadata)

    terminal_metadata =
      Map.merge(state.terminal_metadata, Map.take(metadata, @terminal_metadata_keys))

    %{
      state
      | error: error,
        finish_reason: finish_reason,
        terminal_metadata: terminal_metadata,
        usage: usage,
        warning_sources: warning_sources,
        warnings: warnings
    }
  end

  defp merge_usage(existing, usage) when is_map(usage) do
    ReqLLM.Usage.merge(existing || %{}, usage)
  end

  defp merge_usage(existing, _usage), do: existing

  defp merge_warnings(existing, warnings) when is_list(warnings) do
    Enum.uniq(existing ++ warnings)
  end

  defp warning_values(metadata) do
    case value(metadata, :warnings) || value(metadata, :warning) do
      warning when is_binary(warning) and warning != "" -> [warning]
      warnings when is_list(warnings) -> Enum.filter(warnings, &is_binary/1)
      _other -> []
    end
  end

  defp collect_warning_source(sources, metadata) when map_size(metadata) > 0 do
    if Projection.safe_metadata(metadata) == metadata do
      sources
    else
      [metadata | sources]
    end
  end

  defp collect_warning_source(sources, _metadata), do: sources

  defp safe_map(metadata), do: Projection.safe_metadata(metadata)

  defp values(map, keys) when is_map(map) do
    keys
    |> Enum.flat_map(fn key -> normalize_values(Map.get(map, key)) end)
    |> Enum.uniq()
  end

  defp normalize_values(nil), do: []
  defp normalize_values(values) when is_list(values), do: Enum.reject(values, &is_nil/1)
  defp normalize_values(value), do: [value]

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp pull({:enumerable, enumerable}) do
    enumerable
    |> Enumerable.reduce({:cont, nil}, &suspend/2)
    |> pull_result()
  end

  defp pull({:continuation, continuation}) do
    continuation.({:cont, nil})
    |> pull_result()
  end

  defp pull_result({:suspended, item, continuation}),
    do: {:ok, item, {:continuation, continuation}}

  defp pull_result({:done, _accumulator}), do: :done
  defp pull_result({:halted, _accumulator}), do: :done

  defp suspend(item, _accumulator), do: {:suspend, item}

  defp halt_iterator(%{iterator: {:continuation, continuation}}) do
    continuation.({:halt, nil})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp halt_iterator(_state), do: :ok

  defp normalize_finish_reason(nil), do: :unknown

  defp normalize_finish_reason(reason) when is_atom(reason),
    do: normalize_finish_reason_atom(reason)

  defp normalize_finish_reason(reason) when is_binary(reason) do
    case reason do
      "stop" -> :stop
      "completed" -> :stop
      "end_turn" -> :stop
      "tool_calls" -> :tool_calls
      "tool_use" -> :tool_calls
      "length" -> :length
      "max_tokens" -> :length
      "max_output_tokens" -> :length
      "content_filter" -> :content_filter
      "error" -> :error
      "cancelled" -> :cancelled
      "incomplete" -> :incomplete
      _other -> :unknown
    end
  end

  defp normalize_finish_reason(_reason), do: :unknown

  defp normalize_finish_reason_atom(:tool_use), do: :tool_calls
  defp normalize_finish_reason_atom(:completed), do: :stop
  defp normalize_finish_reason_atom(:end_turn), do: :stop
  defp normalize_finish_reason_atom(:max_tokens), do: :length
  defp normalize_finish_reason_atom(:max_output_tokens), do: :length

  defp normalize_finish_reason_atom(reason)
       when reason in [
              :stop,
              :tool_calls,
              :length,
              :content_filter,
              :error,
              :cancelled,
              :incomplete,
              :unknown
            ],
       do: reason

  defp normalize_finish_reason_atom(_reason), do: :unknown
end
