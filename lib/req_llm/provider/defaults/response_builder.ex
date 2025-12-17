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
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @impl true
  @spec build_response([StreamChunk.t()], map(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def build_response(chunks, metadata, opts) do
    context = Keyword.fetch!(opts, :context)
    model = Keyword.fetch!(opts, :model)

    # Accumulate data from chunks
    acc_data = accumulate_chunks(chunks)

    # Reconstruct tool calls with merged argument fragments
    reconstructed_tool_calls = reconstruct_tool_calls(acc_data)

    # Normalize to ToolCall structs
    normalized_tool_calls = normalize_tool_calls(reconstructed_tool_calls)

    # Build message content
    text_content = acc_data.text_content |> Enum.reverse() |> Enum.join("")
    thinking_content = acc_data.thinking_content |> Enum.reverse() |> Enum.join("")
    content_parts = build_content_parts(text_content, thinking_content, normalized_tool_calls)

    # Build message
    message = %Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(normalized_tool_calls != [], do: normalized_tool_calls),
      metadata: build_message_metadata(metadata)
    }

    # Extract structured object if present
    object = extract_object_from_message(message)

    # Normalize usage
    usage = normalize_usage_fields(metadata[:usage])

    # Normalize finish_reason to atom (providers may emit strings)
    finish_reason = normalize_finish_reason(metadata[:finish_reason])

    # Build response
    base_response = %Response{
      id: metadata[:response_id] || generate_response_id(),
      model: model.id,
      context: context,
      message: message,
      object: object,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: metadata[:provider_meta] || %{},
      error: nil
    }

    # Merge context with new assistant message
    merged_response = Context.merge_response(context, base_response)

    {:ok, merged_response}
  rescue
    error -> {:error, error}
  end

  # ============================================================================
  # Chunk Accumulation
  # ============================================================================

  @doc false
  def accumulate_chunks(chunks) do
    Enum.reduce(
      chunks,
      %{text_content: [], thinking_content: [], tool_calls: [], arg_fragments: %{}},
      &accumulate_chunk/2
    )
  end

  defp accumulate_chunk(%StreamChunk{type: :content, text: text}, acc) do
    %{acc | text_content: [text | acc.text_content]}
  end

  defp accumulate_chunk(%StreamChunk{type: :thinking, text: text}, acc) do
    %{acc | thinking_content: [text | acc.thinking_content]}
  end

  defp accumulate_chunk(%StreamChunk{type: :tool_call} = chunk, acc) do
    tool_call = %{
      id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
      name: chunk.name,
      arguments: chunk.arguments || %{},
      index: Map.get(chunk.metadata, :index, 0)
    }

    %{acc | tool_calls: [tool_call | acc.tool_calls]}
  end

  defp accumulate_chunk(%StreamChunk{type: :meta, metadata: meta}, acc) do
    case meta do
      %{tool_call_args: %{index: index, fragment: fragment}} ->
        existing = Map.get(acc.arg_fragments, index, "")
        %{acc | arg_fragments: Map.put(acc.arg_fragments, index, existing <> fragment)}

      _ ->
        acc
    end
  end

  defp accumulate_chunk(_chunk, acc), do: acc

  # ============================================================================
  # Tool Call Reconstruction
  # ============================================================================

  @doc false
  def reconstruct_tool_calls(%{tool_calls: []}), do: []

  def reconstruct_tool_calls(acc_data) do
    acc_data.tool_calls
    |> Enum.reverse()
    |> Enum.map(&merge_tool_call_arguments(&1, acc_data.arg_fragments))
  end

  defp merge_tool_call_arguments(tool_call, arg_fragments) do
    case Map.get(arg_fragments, tool_call.index) do
      nil ->
        Map.delete(tool_call, :index)

      json_str ->
        case Jason.decode(json_str) do
          {:ok, args} ->
            tool_call
            |> Map.put(:arguments, args)
            |> Map.delete(:index)

          {:error, _} ->
            Map.delete(tool_call, :index)
        end
    end
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
    Enum.map(tool_calls, &normalize_tool_call/1)
  end

  def normalize_tool_calls(_), do: []

  defp normalize_tool_call(%ToolCall{} = call), do: call

  defp normalize_tool_call(%{id: id, name: name, arguments: args}) do
    ToolCall.new(id, name, encode_tool_args(args))
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "arguments" => args}) do
    ToolCall.new(id, name, encode_tool_args(args))
  end

  defp normalize_tool_call(other) when is_map(other) do
    id = Map.get(other, :id) || Map.get(other, "id")
    name = Map.get(other, :name) || Map.get(other, "name")
    args = Map.get(other, :arguments) || Map.get(other, "arguments")
    ToolCall.new(id, name, encode_tool_args(args))
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

    base
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
end
