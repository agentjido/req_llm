defmodule ReqLLM.Provider.ChunkAccumulator do
  @moduledoc """
  Shared streaming-chunk reducer used by both `ReqLLM.StreamServer` (the
  hot path, one chunk at a time) and
  `ReqLLM.Provider.Defaults.ResponseBuilder` (batch, full chunk list at
  end-of-stream).

  Maintains running iodata buffers for text/thinking, a running tool-call
  list, and per-index argument-fragment buffers. Reasoning details and
  logprobs are also collected from `:meta` chunks.

  ## Finalizers

  Two different finalizers exist because StreamServer and ResponseBuilder
  consume the accumulator differently:

    * `finalize_tool_calls_for_response/1` — preserves the historical
      `ResponseBuilder` contract: returns raw maps with `:id`, `:name`,
      `:arguments` (decoded JSON when fragments are present, else the raw
      args from the tool_call chunk). Used to feed
      `ResponseBuilder.normalize_tool_calls/1`.

    * `finalize_message/1` — preserves the historical `StreamServer`
      contract: returns either `nil` (empty acc) or an assistant
      `%ReqLLM.Message{}` ready to attach to OTel content-capture metadata.
      Text content becomes a single `:text` `ContentPart`; tool calls
      become `%ReqLLM.ToolCall{}` structs (with builtin flag preserved).

  Reasoning text is intentionally not surfaced through `finalize_message/1`
  — OTel content capture redacts it anyway and the canonical response
  message is built separately by `ResponseBuilder` with full reasoning
  details.

  ## Performance notes

  The accumulator is on the streaming hot path. To keep `push/2` O(1) per
  chunk we prepend list entries (tool calls, reasoning details, logprobs)
  and reverse them at finalize time. Text and thinking buffers are iodata
  — also O(1) per chunk. Argument fragments are iodata buffers keyed by
  tool-call index, joined only at finalize time. A stream with N chunks
  costs O(N) total work, not O(N²).
  """

  alias ReqLLM.{Message, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk

  require Logger

  @tool_call_control_metadata_keys [
    :id,
    "id",
    :index,
    "index",
    :name,
    "name",
    :builtin?,
    "builtin?",
    :start,
    "start",
    :expects_arg_fragments,
    "expects_arg_fragments",
    :args_fragment_expected?,
    "args_fragment_expected?",
    :done_at_unix_nano,
    "done_at_unix_nano"
  ]

  @type tool_call_record :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => term(),
          required(:index) => non_neg_integer(),
          optional(:builtin?) => true,
          optional(:expects_arg_fragments) => true,
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          text_content: iodata(),
          thinking_content: iodata(),
          tool_calls: [tool_call_record()],
          arg_fragments: %{optional(non_neg_integer()) => iodata()},
          reasoning_details: [term()],
          logprobs: [term()],
          finish_reason: atom() | String.t() | nil,
          usage: map() | nil
        }

  defstruct text_content: [],
            thinking_content: [],
            tool_calls: [],
            arg_fragments: %{},
            reasoning_details: [],
            logprobs: [],
            finish_reason: nil,
            usage: nil

  @doc "Returns an empty accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds a list of chunks through `push/2`. Convenience wrapper for the
  batch path (`ResponseBuilder`).
  """
  @spec reduce(t(), [StreamChunk.t()]) :: t()
  def reduce(%__MODULE__{} = acc, chunks) when is_list(chunks) do
    Enum.reduce(chunks, acc, &push(&2, &1))
  end

  @doc """
  Folds a single chunk into the accumulator. Hot path — O(1) per chunk.
  """
  @spec push(t(), StreamChunk.t()) :: t()
  def push(%__MODULE__{} = acc, %StreamChunk{type: :content, text: text})
      when is_binary(text) and text != "" do
    %{acc | text_content: [acc.text_content, text]}
  end

  def push(%__MODULE__{} = acc, %StreamChunk{type: :thinking, text: text})
      when is_binary(text) and text != "" do
    %{acc | thinking_content: [acc.thinking_content, text]}
  end

  def push(%__MODULE__{} = acc, %StreamChunk{type: :tool_call} = chunk) do
    metadata = chunk.metadata || %{}
    name = chunk.name || Map.get(metadata, :name) || Map.get(metadata, "name")

    if is_binary(name) and name != "" do
      id = Map.get(metadata, :id) || Map.get(metadata, "id") || generate_tool_call_id()
      index = Map.get(metadata, :index, Map.get(metadata, "index", 0))

      tool_call =
        %{
          id: id,
          name: name,
          arguments: chunk.arguments || %{},
          index: index
        }
        |> maybe_put_tool_call_metadata(metadata)
        |> maybe_mark_expects_arg_fragments(metadata)
        |> ToolCall.put_builtin_flag(ToolCall.flagged_builtin?(metadata))

      # Prepend (O(1)); finalizers reverse to restore arrival order.
      acc = %{acc | tool_calls: [tool_call | acc.tool_calls]}
      seed_arg_fragment(acc, index, metadata)
    else
      acc
    end
  end

  def push(%__MODULE__{} = acc, %StreamChunk{type: :meta, metadata: metadata})
      when is_map(metadata) do
    acc
    |> push_arg_fragment(metadata)
    |> push_reasoning_details(metadata)
    |> push_logprobs(metadata)
    |> push_finish_reason(metadata)
    |> push_usage(metadata)
  end

  def push(%__MODULE__{} = acc, _chunk), do: acc

  # Some servers (e.g. llama.cpp, vLLM) begin streaming `arguments` in the same
  # chunk as the tool name — valid per the OpenAI streaming spec. That leading
  # fragment (often just `"{"`) doesn't parse as complete JSON, so the decoder
  # keeps it as `:raw_arguments`. Seed it as the first argument fragment for this
  # index so the continuation fragments append to it and the joined JSON parses;
  # otherwise the opening brace is lost and the tool receives empty arguments.
  defp seed_arg_fragment(acc, index, metadata) do
    case Map.get(metadata, :raw_arguments) || Map.get(metadata, "raw_arguments") do
      raw when is_binary(raw) and raw != "" ->
        %{acc | arg_fragments: Map.update(acc.arg_fragments, index, [raw], &[&1, raw])}

      _ ->
        acc
    end
  end

  defp push_arg_fragment(acc, metadata) do
    case tool_call_args_fragment(metadata) do
      {index, fragment} ->
        %{acc | arg_fragments: Map.update(acc.arg_fragments, index, [fragment], &[&1, fragment])}

      nil ->
        acc
    end
  end

  # Stored reversed (newest first) — finalizers reverse to restore order.
  defp push_reasoning_details(acc, %{reasoning_details: details}) when is_list(details) do
    %{acc | reasoning_details: Enum.reverse(details, acc.reasoning_details)}
  end

  defp push_reasoning_details(acc, _metadata), do: acc

  defp push_logprobs(acc, %{logprobs: tokens}) when is_list(tokens) do
    %{acc | logprobs: Enum.reverse(tokens, acc.logprobs)}
  end

  defp push_logprobs(acc, _metadata), do: acc

  # Latest finish_reason wins — streaming providers may emit interim values
  # and a final terminal value. The raw (string or atom) form is stored;
  # callers normalize when finalizing.
  defp push_finish_reason(acc, %{finish_reason: reason}) when not is_nil(reason) do
    %{acc | finish_reason: reason}
  end

  defp push_finish_reason(acc, _metadata), do: acc

  # Usage is merged via `ReqLLM.Usage.merge/2` — handles cumulative
  # streaming token counters (latest-max wins per field) plus recomputed
  # totals.
  defp push_usage(acc, %{usage: usage}) when is_map(usage) do
    %{acc | usage: ReqLLM.Usage.merge(acc.usage || %{}, usage)}
  end

  defp push_usage(acc, _metadata), do: acc

  defp tool_call_args_fragment(metadata) do
    args = Map.get(metadata, :tool_call_args) || Map.get(metadata, "tool_call_args")

    with args when is_map(args) <- args,
         fragment when is_binary(fragment) <-
           Map.get(args, :fragment) || Map.get(args, "fragment") do
      {Map.get(args, :index, Map.get(args, "index", 0)), fragment}
    else
      _ -> nil
    end
  end

  defp maybe_put_tool_call_metadata(tool_call, metadata) do
    metadata = Map.drop(metadata, @tool_call_control_metadata_keys)

    if map_size(metadata) > 0 do
      Map.put(tool_call, :metadata, metadata)
    else
      tool_call
    end
  end

  defp maybe_mark_expects_arg_fragments(tool_call, metadata) do
    if expects_arg_fragments?(metadata) do
      Map.put(tool_call, :expects_arg_fragments, true)
    else
      tool_call
    end
  end

  defp expects_arg_fragments?(metadata) do
    [
      :expects_arg_fragments,
      "expects_arg_fragments",
      :args_fragment_expected?,
      "args_fragment_expected?",
      :start,
      "start"
    ]
    |> Enum.any?(&truthy?(Map.get(metadata, &1)))
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  @doc "Returns the concatenated text content as a binary."
  @spec finalize_text(t()) :: String.t()
  def finalize_text(%__MODULE__{text_content: iodata}), do: IO.iodata_to_binary(iodata)

  @doc "Returns the concatenated thinking content as a binary."
  @spec finalize_thinking(t()) :: String.t()
  def finalize_thinking(%__MODULE__{thinking_content: iodata}), do: IO.iodata_to_binary(iodata)

  @doc "Returns reasoning details in arrival order."
  @spec finalize_reasoning_details(t()) :: [term()]
  def finalize_reasoning_details(%__MODULE__{reasoning_details: details}),
    do: Enum.reverse(details)

  @doc "Returns logprob tokens in arrival order."
  @spec finalize_logprobs(t()) :: [term()]
  def finalize_logprobs(%__MODULE__{logprobs: tokens}), do: Enum.reverse(tokens)

  @doc """
  Returns the most recently observed `finish_reason` from meta chunks, or
  `nil` if no meta chunk surfaced one. The value is returned raw (atom or
  string) — callers normalize.
  """
  @spec finalize_finish_reason(t()) :: atom() | String.t() | nil
  def finalize_finish_reason(%__MODULE__{finish_reason: reason}), do: reason

  @doc """
  Returns the merged usage map (or `nil` if no meta chunk surfaced usage).
  """
  @spec finalize_usage(t()) :: map() | nil
  def finalize_usage(%__MODULE__{usage: usage}), do: usage

  @doc """
  Returns tool calls in the format `ResponseBuilder.normalize_tool_calls/1`
  expects: maps with `:id`, `:name`, `:arguments`, and optionally a
  `:builtin?` flag. If argument fragments were observed and decode
  successfully, arguments are the decoded JSON; otherwise they fall back
  to the raw arguments captured from the tool_call chunk.
  """
  @spec finalize_tool_calls_for_response(t()) :: [map()]
  def finalize_tool_calls_for_response(%__MODULE__{
        tool_calls: tool_calls,
        arg_fragments: fragments
      }) do
    tool_calls
    |> Enum.reverse()
    |> Enum.map(&response_tool_call(&1, fragments))
  end

  defp response_tool_call(tool_call, fragments) do
    case Map.get(fragments, tool_call.index) do
      nil ->
        if Map.get(tool_call, :expects_arg_fragments, false) do
          args_lost(tool_call, :missing_fragments)
        else
          drop_accumulator_fields(tool_call)
        end

      iodata ->
        json = IO.iodata_to_binary(iodata)
        response_tool_call_from_json(tool_call, json)
    end
  end

  defp response_tool_call_from_json(tool_call, "") do
    drop_accumulator_fields(tool_call)
  end

  defp response_tool_call_from_json(tool_call, json) do
    case Jason.decode(json) do
      {:ok, args} ->
        tool_call
        |> Map.put(:arguments, args)
        |> drop_accumulator_fields()

      {:error, _} ->
        args_lost(tool_call, :json_decode_error, json)
    end
  end

  defp args_lost(tool_call, reason, json \\ nil) do
    metadata = %{
      tool_name: tool_call.name,
      tool_call_id: tool_call.id,
      reason: reason
    }

    :telemetry.execute([:req_llm, :tool_call_args_lost], %{count: 1}, metadata)
    Logger.warning(args_lost_message(metadata, json), Map.to_list(metadata))

    tool_call
    |> drop_accumulator_fields()
    |> Map.update(:metadata, %{error: {:args_lost, reason}}, fn existing ->
      Map.put(existing, :error, {:args_lost, reason})
    end)
  end

  defp drop_accumulator_fields(tool_call) do
    tool_call
    |> Map.delete(:index)
    |> Map.delete(:expects_arg_fragments)
  end

  defp args_lost_message(%{reason: reason, tool_name: tool_name, tool_call_id: tool_call_id}, nil) do
    "req_llm tool_call args_lost reason=#{reason} tool_name=#{tool_name} tool_call_id=#{tool_call_id}"
  end

  defp args_lost_message(
         %{reason: reason, tool_name: tool_name, tool_call_id: tool_call_id},
         json
       ) do
    "req_llm tool_call args_lost reason=#{reason} tool_name=#{tool_name} " <>
      "tool_call_id=#{tool_call_id} json_bytes=#{byte_size(json)}"
  end

  @doc """
  Returns a partial assistant `%ReqLLM.Message{}` for OTel content
  capture, or `nil` when the accumulator has no text and no tool calls.
  Reasoning is intentionally `nil` — OTel content capture redacts it.
  """
  @spec finalize_message(t()) :: Message.t() | nil
  def finalize_message(%__MODULE__{} = acc) do
    text = finalize_text(acc)
    tool_calls = finalize_message_tool_calls(acc)

    content_parts =
      if text == "" do
        []
      else
        [%ContentPart{type: :text, text: text, metadata: %{}}]
      end

    if content_parts == [] and tool_calls == [] do
      nil
    else
      %Message{
        role: :assistant,
        content: content_parts,
        name: nil,
        tool_call_id: nil,
        tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
        metadata: %{},
        reasoning_details: nil
      }
    end
  end

  defp finalize_message_tool_calls(%__MODULE__{tool_calls: tool_calls, arg_fragments: fragments}) do
    tool_calls
    |> Enum.reverse()
    |> Enum.map(&message_tool_call_struct(&1, fragments))
  end

  defp message_tool_call_struct(tool_call, fragments) do
    args = message_tool_call_args(tool_call, fragments)

    constructor =
      if ToolCall.flagged_builtin?(tool_call),
        do: &ToolCall.new_builtin/3,
        else: &ToolCall.new/3

    constructor.(tool_call.id, tool_call.name, encode_tool_call_args(args))
    |> ToolCall.put_metadata(ToolCall.metadata(tool_call))
  end

  defp message_tool_call_args(%{index: index, arguments: arguments}, fragments) do
    case Map.get(fragments, index) do
      nil ->
        arguments

      iodata ->
        json = IO.iodata_to_binary(iodata)

        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          {:error, _reason} -> arguments
        end
    end
  end

  defp encode_tool_call_args(args) when is_binary(args), do: args

  defp encode_tool_call_args(args) when is_map(args) or is_list(args) do
    case Jason.encode(args) do
      {:ok, json} -> json
      {:error, _reason} -> "{}"
    end
  end

  defp encode_tool_call_args(_args), do: "{}"

  defp generate_tool_call_id, do: "call_#{ReqLLM.ID.uuid7()}"
end
