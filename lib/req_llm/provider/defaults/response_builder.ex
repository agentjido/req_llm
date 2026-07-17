defmodule ReqLLM.Provider.Defaults.ResponseBuilder do
  @moduledoc """
  Default ResponseBuilder implementation for OpenAI-compatible providers.

  This module provides the standard Response assembly logic used by most
  providers (OpenAI Chat API, xAI, Groq, Cerebras, OpenRouter, etc.).

  Provider-specific builders can delegate to this implementation and then
  apply their own post-processing, or override entirely.

  ## Responsibilities

  1. Accumulate content from StreamChunks (text, thinking, tool_calls)
  2. Merge fragmented tool call arguments
  3. Normalize tool calls to `ToolCall` structs
  4. Build `Message` with proper content parts
  5. Construct final `Response` struct with metadata

  ## Usage

  This is typically called via `ResponseBuilder.for_model/1`:

      builder = ResponseBuilder.for_model(model)
      {:ok, response} = builder.build_response(chunks, metadata, opts)

  Or directly for OpenAI-compatible providers:

      {:ok, response} = Defaults.ResponseBuilder.build_response(chunks, metadata, opts)

  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.ChunkAccumulator
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @impl true
  @spec build_response([StreamChunk.t()], map(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def build_response(chunks, metadata, opts) do
    do_build_response(chunks, metadata, opts, :stream)
  end

  @doc false
  @spec build_buffered_response([StreamChunk.t()], map(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def build_buffered_response(chunks, metadata, opts) do
    do_build_response(chunks, metadata, opts, :buffered)
  end

  defp do_build_response(chunks, metadata, opts, profile) do
    context = Keyword.fetch!(opts, :context)
    model = Keyword.fetch!(opts, :model)

    acc =
      chunks
      |> accumulator_chunks(profile)
      |> then(&ChunkAccumulator.reduce(ChunkAccumulator.new(), &1))

    reconstructed_tool_calls = ChunkAccumulator.finalize_tool_calls_for_response(acc)
    normalized_tool_calls = normalize_tool_calls(reconstructed_tool_calls, profile)

    text_content = ChunkAccumulator.finalize_text(acc)
    thinking_content = ChunkAccumulator.finalize_thinking(acc)

    content_parts =
      materialize_content_parts(
        profile,
        chunks,
        text_content,
        thinking_content,
        normalized_tool_calls
      )

    reasoning_details = materialize_reasoning_details(profile, chunks, acc, model.provider)

    message = %Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(normalized_tool_calls != [], do: normalized_tool_calls),
      metadata: materialize_message_metadata(profile, metadata),
      reasoning_details: reasoning_details
    }

    object = materialize_object(profile, message, metadata)
    usage = normalize_usage_fields(metadata[:usage])
    finish_reason = normalize_finish_reason(metadata[:finish_reason])
    base_provider_meta = metadata[:provider_meta] || %{}

    provider_meta =
      case ChunkAccumulator.finalize_logprobs(acc) do
        [] -> base_provider_meta
        tokens -> Map.put(base_provider_meta, :logprobs, tokens)
      end

    base_response = %Response{
      id: materialize_response_id(profile, metadata),
      model: materialize_model(profile, metadata, model),
      context: context,
      message: message,
      object: object,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: provider_meta,
      error: nil
    }

    merged_response = Context.merge_response(context, base_response)

    {:ok, merged_response}
  rescue
    error -> {:error, error}
  end

  # ============================================================================
  # Tool Call Normalization
  # ============================================================================

  @doc """
  Normalize tool calls to `ToolCall` structs.

  Accepts various input formats:
  - `ToolCall` structs (passed through)
  - Maps with atom keys `%{id:, name:, arguments:}`
  - Maps with string keys `%{"id" =>, "name" =>, "arguments" =>}`

  Arguments can be maps (encoded to JSON) or JSON strings (passed through).
  """
  @spec normalize_tool_calls([map() | ToolCall.t()]) :: [ToolCall.t()]
  def normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    normalize_tool_calls(tool_calls, :stream)
  end

  def normalize_tool_calls(_), do: []

  defp normalize_tool_calls(tool_calls, profile) when is_list(tool_calls) do
    Enum.map(tool_calls, &normalize_tool_call(&1, profile))
  end

  defp normalize_tool_calls(_tool_calls, _profile), do: []

  defp normalize_tool_call(%ToolCall{} = call, _profile), do: call

  defp normalize_tool_call(%{id: id, name: name, arguments: args} = m, profile) do
    constructor =
      if ToolCall.flagged_builtin?(m), do: &ToolCall.new_builtin/3, else: &ToolCall.new/3

    constructor.(id, name, encode_tool_args(args))
    |> put_tool_call_metadata(m, profile)
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "arguments" => args} = m, profile) do
    constructor =
      if ToolCall.flagged_builtin?(m), do: &ToolCall.new_builtin/3, else: &ToolCall.new/3

    constructor.(id, name, encode_tool_args(args))
    |> put_tool_call_metadata(m, profile)
  end

  defp normalize_tool_call(other, profile) when is_map(other) do
    constructor =
      if ToolCall.flagged_builtin?(other), do: &ToolCall.new_builtin/3, else: &ToolCall.new/3

    constructor.(other[:id], other[:name], encode_tool_args(other[:arguments]))
    |> put_tool_call_metadata(other, profile)
  end

  defp put_tool_call_metadata(%ToolCall{} = call, _source, :buffered), do: call

  defp put_tool_call_metadata(%ToolCall{} = call, source, _profile) do
    ToolCall.put_metadata(call, ToolCall.metadata(source))
  end

  defp encode_tool_args(args) when is_binary(args), do: args
  defp encode_tool_args(nil), do: Jason.encode!(%{})
  defp encode_tool_args(args), do: Jason.encode!(args)

  # ============================================================================
  # Content Building
  # ============================================================================

  @doc """
  Build content parts from text, thinking, and tool calls.

  Special case: if there are no tool calls and text looks like JSON,
  it may be structured output and is parsed accordingly.
  """
  @spec build_content_parts(String.t(), String.t(), [ToolCall.t()]) :: [ContentPart.t() | map()]
  def build_content_parts(text_content, thinking_content, tool_calls) do
    if tool_calls == [] and text_content != "" and looks_like_json?(text_content) do
      case Jason.decode(text_content) do
        {:ok, parsed_json} when is_map(parsed_json) ->
          [%{type: :object, object: parsed_json}]

        _ ->
          build_standard_content_parts(text_content, thinking_content)
      end
    else
      build_standard_content_parts(text_content, thinking_content)
    end
  end

  defp build_standard_content_parts(text_content, thinking_content) do
    []
    |> maybe_add_text_part(text_content)
    |> maybe_add_thinking_part(thinking_content)
  end

  defp looks_like_json?(text) do
    trimmed = String.trim(text)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp maybe_add_text_part(parts, ""), do: parts

  defp maybe_add_text_part(parts, text) do
    parts ++ [%ContentPart{type: :text, text: text}]
  end

  defp maybe_add_thinking_part(parts, ""), do: parts

  defp maybe_add_thinking_part(parts, thinking) do
    parts ++ [%ContentPart{type: :thinking, text: thinking}]
  end

  # ============================================================================
  # Object Extraction
  # ============================================================================

  defp extract_object_from_message(%Message{content: content, tool_calls: tool_calls}) do
    with nil <- extract_from_tool_calls(tool_calls) do
      extract_from_content(content)
    end
  end

  defp extract_from_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.find_value(tool_calls, &extract_structured_output_args/1)
  end

  defp extract_from_tool_calls(_), do: nil

  defp extract_structured_output_args(%ToolCall{} = tc) do
    if ToolCall.matches_name?(tc, "structured_output") do
      ToolCall.args_map(tc)
    end
  end

  defp extract_structured_output_args(%{name: "structured_output", arguments: args})
       when is_map(args) do
    args
  end

  defp extract_structured_output_args(_), do: nil

  defp extract_from_content(content) when is_list(content) do
    Enum.find_value(content, fn
      %{type: :object, object: obj} when is_map(obj) -> obj
      _ -> nil
    end)
  end

  defp accumulator_chunks(chunks, :buffered) do
    Enum.map(chunks, &restore_buffered_tool_arguments/1)
  end

  defp accumulator_chunks(chunks, _profile), do: chunks

  defp restore_buffered_tool_arguments(
         %StreamChunk{
           type: :tool_call,
           metadata: %{buffered_arguments: arguments} = metadata
         } = chunk
       )
       when is_binary(arguments) do
    %{chunk | arguments: arguments, metadata: Map.delete(metadata, :buffered_arguments)}
  end

  defp restore_buffered_tool_arguments(
         %StreamChunk{
           type: :tool_call,
           metadata: %{unparseable_arguments: true, raw_arguments: raw_arguments} = metadata
         } = chunk
       )
       when is_binary(raw_arguments) do
    %{chunk | arguments: raw_arguments, metadata: drop_buffered_argument_metadata(metadata)}
  end

  defp restore_buffered_tool_arguments(
         %StreamChunk{type: :tool_call, metadata: %{invalid_arguments: true} = metadata} = chunk
       ) do
    %{chunk | metadata: drop_buffered_argument_metadata(metadata)}
  end

  defp restore_buffered_tool_arguments(chunk), do: chunk

  defp drop_buffered_argument_metadata(metadata) do
    Map.drop(metadata, [
      :decoded_arguments,
      :invalid_arguments,
      :raw_arguments,
      :unparseable_arguments
    ])
  end

  defp materialize_content_parts(:buffered, chunks, _text, _thinking, _tool_calls) do
    Enum.flat_map(chunks, fn
      %StreamChunk{type: :content, text: text} -> [%ContentPart{type: :text, text: text}]
      %StreamChunk{type: :thinking, text: text} -> [%ContentPart{type: :thinking, text: text}]
      _chunk -> []
    end)
  end

  defp materialize_content_parts(_profile, _chunks, text, thinking, tool_calls) do
    build_content_parts(text, thinking, tool_calls)
  end

  defp materialize_reasoning_details(:buffered, _chunks, acc, _provider) do
    case ChunkAccumulator.finalize_reasoning_details(acc) do
      [] -> nil
      details -> details
    end
  end

  defp materialize_reasoning_details(_profile, chunks, acc, provider) do
    case ChunkAccumulator.finalize_reasoning_details(acc) do
      [] -> extract_reasoning_from_thinking_chunks(chunks, provider)
      details -> details
    end
  end

  defp materialize_message_metadata(:buffered, metadata) do
    Map.get(metadata, :message_metadata, %{})
  end

  defp materialize_message_metadata(_profile, metadata), do: build_message_metadata(metadata)

  defp materialize_object(:buffered, _message, metadata), do: Map.get(metadata, :object)
  defp materialize_object(_profile, message, _metadata), do: extract_object_from_message(message)

  defp materialize_model(:buffered, metadata, model) do
    case Map.fetch(metadata, :response_model) do
      {:ok, response_model} -> response_model
      :error -> model.id
    end
  end

  defp materialize_model(_profile, _metadata, model), do: model.id

  defp materialize_response_id(:buffered, metadata) do
    case Map.fetch(metadata, :response_id) do
      {:ok, response_id} -> response_id
      :error -> generate_response_id()
    end
  end

  defp materialize_response_id(_profile, metadata) do
    metadata[:response_id] || generate_response_id()
  end

  # ============================================================================
  # Metadata Helpers
  # ============================================================================

  defp build_message_metadata(metadata) do
    base = %{}

    base =
      if metadata[:response_id] do
        Map.put(base, :response_id, metadata[:response_id])
      else
        base
      end

    base =
      if metadata[:phase] do
        Map.put(base, :phase, metadata[:phase])
      else
        base
      end

    if metadata[:phase_items] do
      Map.put(base, :phase_items, metadata[:phase_items])
    else
      base
    end
  end

  defp generate_response_id do
    "resp_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp normalize_usage_fields(nil), do: nil

  defp normalize_usage_fields(usage) when is_map(usage) do
    usage
    |> Map.put_new(:cached_tokens, Map.get(usage, :cached_input, 0))
    |> Map.put_new(:reasoning_tokens, Map.get(usage, :reasoning, 0))
  end

  # Normalize finish_reason to atoms (providers may emit strings)
  # Uses explicit mapping to avoid atom table exhaustion from untrusted input
  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(reason) when is_atom(reason), do: reason
  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("completed"), do: :stop
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("max_tokens"), do: :length
  defp normalize_finish_reason("max_output_tokens"), do: :length
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason("tool_use"), do: :tool_calls
  defp normalize_finish_reason("end_turn"), do: :stop
  defp normalize_finish_reason("error"), do: :error
  defp normalize_finish_reason("cancelled"), do: :cancelled
  defp normalize_finish_reason("incomplete"), do: :incomplete
  # Fallback to :unknown for any unrecognized values to prevent atom table exhaustion
  defp normalize_finish_reason(_other), do: :unknown

  defp extract_reasoning_from_thinking_chunks(chunks, provider) do
    thinking_chunks =
      Enum.filter(chunks, fn
        %StreamChunk{type: :thinking} -> true
        _ -> false
      end)

    case thinking_chunks do
      [] ->
        nil

      chunks_list ->
        chunks_list
        |> Enum.with_index()
        |> Enum.map(fn {chunk, index} ->
          meta = chunk.metadata

          %Message.ReasoningDetails{
            text: chunk.text,
            signature: meta[:signature],
            encrypted?: meta[:encrypted?] || false,
            provider: meta[:provider] || provider,
            format: meta[:format] || "openai-reasoning-content-v1",
            index: index,
            provider_data: meta[:provider_data]
          }
        end)
    end
  end
end
