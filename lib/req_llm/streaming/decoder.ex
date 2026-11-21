defmodule ReqLLM.Streaming.Decoder do
  @moduledoc false

  alias ReqLLM.StreamChunk
  alias ReqLLM.Streaming.SSE

  defstruct [
    :provider_mod,
    :model,
    :protocol_parser,
    :protocol_state,
    :provider_state,
    :provider_opts
  ]

  @type t :: %__MODULE__{
          provider_mod: module(),
          model: LLMDB.Model.t(),
          protocol_parser: (binary(), term() -> term()),
          protocol_state: term(),
          provider_state: term(),
          provider_opts: keyword()
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    provider_mod = Keyword.fetch!(opts, :provider_mod)
    model = Keyword.fetch!(opts, :model)
    provider_opts = Keyword.get(opts, :provider_opts) || []

    provider_state =
      if not Keyword.get(opts, :canonical_stream?, false) do
        init_provider_state(provider_mod, model, provider_opts)
      end

    parser = Keyword.get(opts, :protocol_parser)

    %__MODULE__{
      provider_mod: provider_mod,
      model: model,
      provider_state: provider_state,
      provider_opts: provider_opts,
      protocol_parser:
        if(is_function(parser, 2), do: parser, else: http_protocol_parser(provider_mod))
    }
  end

  @doc false
  @spec decode(binary(), t()) ::
          {:ok, [StreamChunk.t()], boolean(), t()} | {:error, term(), t()}
  def decode(chunk, %__MODULE__{} = decoder) do
    case decoder.protocol_parser.(chunk, decoder.protocol_state) do
      {:ok, events, protocol_state} ->
        {chunks, provider_state} = decode_events(events, decoder)

        terminated? =
          Enum.any?(events, &termination_event?/1) or Enum.any?(chunks, &terminal_chunk?/1)

        {:ok, chunks, terminated?,
         %{decoder | protocol_state: protocol_state, provider_state: provider_state}}

      {:incomplete, protocol_state} ->
        {:ok, [], false, %{decoder | protocol_state: protocol_state}}

      {:error, reason} ->
        {:error, reason, decoder}
    end
  end

  @doc "Flush pending protocol events before flushing provider state."
  @spec flush_protocol(t()) :: {[StreamChunk.t()], boolean(), t()}
  def flush_protocol(%__MODULE__{} = decoder) do
    {events, protocol_state} = SSE.flush(decoder.protocol_state)
    {chunks, provider_state} = decode_events(events, decoder)
    terminated? = Enum.any?(events, &termination_event?/1)

    {chunks, terminated?,
     %{decoder | protocol_state: protocol_state, provider_state: provider_state}}
  end

  @doc "Flush provider state after the caller has consumed pending protocol chunks."
  @spec flush_provider(t()) :: {[StreamChunk.t()], t()}
  def flush_provider(%__MODULE__{} = decoder) do
    {chunks, provider_state} =
      if exported?(decoder.provider_mod, :flush_stream_state, 2) do
        decoder.provider_mod.flush_stream_state(decoder.model, decoder.provider_state)
      else
        {[], decoder.provider_state}
      end

    {chunks, %{decoder | provider_state: provider_state}}
  end

  @doc "Reset for HTTP fallback using the provider protocol parser, ignoring the initial override."
  @spec reset_http(t()) :: t()
  def reset_http(%__MODULE__{} = decoder) do
    provider_opts = decoder.provider_opts || []

    %{
      decoder
      | protocol_parser: http_protocol_parser(decoder.provider_mod),
        protocol_state: nil,
        provider_opts: provider_opts,
        provider_state: init_provider_state(decoder.provider_mod, decoder.model, provider_opts)
    }
  end

  @doc false
  @spec terminal_chunk?(term()) :: boolean()
  def terminal_chunk?(%StreamChunk{type: :meta, metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :terminal?) == true or Map.get(metadata, "terminal?") == true
  end

  def terminal_chunk?(_chunk), do: false

  defp http_protocol_parser(provider_mod) do
    if exported?(provider_mod, :parse_stream_protocol, 2) do
      fn chunk, buffer -> provider_mod.parse_stream_protocol(chunk, buffer) end
    else
      &ReqLLM.Provider.parse_stream_protocol/2
    end
  end

  defp init_provider_state(provider_mod, model, provider_opts) do
    cond do
      exported?(provider_mod, :init_stream_state, 2) ->
        provider_mod.init_stream_state(model, provider_opts)

      exported?(provider_mod, :init_stream_state, 1) ->
        provider_mod.init_stream_state(model)

      true ->
        nil
    end
  end

  defp decode_events(events, decoder) do
    {chunks, provider_state} =
      Enum.reduce(events, {[], decoder.provider_state}, fn event, {acc, provider_state} ->
        case SSE.process_sse_event(event) do
          nil ->
            {acc, provider_state}

          processed_event ->
            {new_chunks, provider_state} =
              decode_provider_event(processed_event, decoder, provider_state)

            {Enum.reduce(new_chunks, acc, fn chunk, acc -> [chunk | acc] end), provider_state}
        end
      end)

    {Enum.reverse(chunks), provider_state}
  end

  defp decode_provider_event(event, decoder, provider_state) do
    cond do
      exported?(decoder.provider_mod, :decode_stream_event, 3) ->
        decoder.provider_mod.decode_stream_event(event, decoder.model, provider_state)

      exported?(decoder.provider_mod, :decode_stream_event, 2) ->
        {decoder.provider_mod.decode_stream_event(event, decoder.model), provider_state}

      true ->
        {ReqLLM.Provider.Defaults.default_decode_stream_event(event, decoder.model),
         provider_state}
    end
  end

  defp exported?(provider_mod, fun, arity) do
    Code.ensure_loaded?(provider_mod) and function_exported?(provider_mod, fun, arity)
  end

  defp termination_event?(%{data: "[DONE]"}), do: true
  defp termination_event?(%{data: %{"done" => true}}), do: true
  defp termination_event?(%{data: %{"type" => "message_stop"}}), do: true
  defp termination_event?(%{data: %{"type" => "response.completed"}}), do: true
  defp termination_event?(_), do: false
end
