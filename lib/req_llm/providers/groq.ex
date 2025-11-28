defmodule ReqLLM.Providers.Groq do
  @moduledoc """
  Groq provider – 100% OpenAI Chat Completions compatible with Groq's high-performance hardware.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed – leverages the standard OpenAI wire format.

  ## Groq-Specific Extensions

  Beyond standard OpenAI parameters, Groq supports:
  - `service_tier` - Performance tier (auto, on_demand, flex, performance)
  - `reasoning_effort` - Reasoning level (none, default, low, medium, high)
  - `reasoning_format` - Format for reasoning output
  - `search_settings` - Web search configuration
  - `compound_custom` - Custom Compound systems configuration
  - `logit_bias` - Token bias adjustments

  See `provider_schema/0` for the complete Groq-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      GROQ_API_KEY=gsk_...
  """

  use ReqLLM.Provider,
    id: :groq,
    default_base_url: "https://api.groq.com/openai/v1",
    default_env_key: "GROQ_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, maybe_put_skip: 4]

  require Logger

  @provider_schema [
    service_tier: [
      type: {:in, ~w(auto on_demand flex performance)},
      doc: "Performance tier for Groq requests"
    ],
    reasoning_format: [
      type: :string,
      doc: "Format for reasoning output"
    ],
    search_settings: [
      type: :map,
      doc: "Web search configuration with include/exclude domains"
    ],
    compound_custom: [
      type: :map,
      doc: "Custom configuration for Compound systems"
    ]
  ]

  @doc """
  Custom prepare_request for :object operations to maintain Groq-specific max_tokens handling.

  Ensures that structured output requests have adequate token limits while delegating
  other operations to the default implementation.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{type: "function", function: %{name: "structured_output"}})

    # Adjust max_tokens for structured output with Groq-specific minimums
    opts_with_tokens =
      case Keyword.get(opts_with_tool, :max_tokens) do
        nil -> Keyword.put(opts_with_tool, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_tool, :max_tokens, 200)
        _tokens -> opts_with_tool
      end

    # Preserve the :object operation for response decoding
    opts_with_operation = Keyword.put(opts_with_tokens, :operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_operation)
  end

  # Delegate all other operations to defaults
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    warnings = []

    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    {opts, warnings} =
      if reasoning_effort && !supports_reasoning_effort?(model) do
        warning =
          "reasoning_effort is not supported for #{model.id} (uses <think> tags instead)"

        {opts, [warning | warnings]}
      else
        opts =
          case reasoning_effort do
            :low -> Keyword.put(opts, :reasoning_effort, "low")
            :medium -> Keyword.put(opts, :reasoning_effort, "medium")
            :high -> Keyword.put(opts, :reasoning_effort, "high")
            :default -> opts
            nil -> opts
            other -> Keyword.put(opts, :reasoning_effort, other)
          end

        {opts, warnings}
      end

    opts = Keyword.delete(opts, :reasoning_token_budget)

    {opts, Enum.reverse(warnings)}
  end

  defp supports_reasoning_effort?(%{model: model_name}) do
    !String.contains?(model_name, ["deepseek", "qwen"])
  end

  @doc """
  Custom body encoding that adds Groq-specific extensions to the default OpenAI-compatible format.

  Adds support for:
  - service_tier (auto, on_demand, flex, performance)
  - reasoning_effort (none, default, low, medium, high)
  - reasoning_format
  - search_settings
  - compound_custom
  - logit_bias (in addition to standard options)
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)
    body = Jason.decode!(request.body)

    enhanced_body =
      body
      |> translate_tool_choice_format()
      |> maybe_put_skip(:service_tier, request.options[:service_tier], ["auto"])
      |> maybe_put_skip(:reasoning_effort, request.options[:reasoning_effort], ["default"])
      |> maybe_put(:reasoning_format, request.options[:reasoning_format])
      |> maybe_put(:search_settings, request.options[:search_settings])
      |> maybe_put(:compound_custom, request.options[:compound_custom])
      |> maybe_put(:logit_bias, request.options[:logit_bias])

    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  defp translate_tool_choice_format(body) do
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

    if type == "tool" && name do
      replacement =
        if is_map_key(tool_choice, :type) do
          %{type: "function", function: %{name: name}}
        else
          %{"type" => "function", "function" => %{"name" => name}}
        end

      Map.put(body, body_key, replacement)
    else
      body
    end
  end

  @doc """
  Custom attach_stream that ensures translate_options is called for streaming requests.

  This is necessary because the default streaming path doesn't call translate_options,
  which means model-specific option normalization (like omitting reasoning_effort for qwen models)
  wouldn't be applied to streaming requests.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    {translated_opts, _warnings} = translate_options(:chat, model, opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, translated_opts)
    opts_with_base_url = Keyword.put(translated_opts, :base_url, base_url)
    ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts_with_base_url, finch_name)
  end

  @doc """
  Initialize streaming state for <think> tag normalization.

  Returns initial state with :text mode and empty buffer.
  """
  @impl ReqLLM.Provider
  def init_stream_state(_model) do
    %{mode: :text, buffer: ""}
  end

  @doc """
  Stateful SSE event decoding that normalizes `<think>` tags.

  Maintains state across events to handle tags split across chunks.
  Returns updated chunks and new state.
  """
  @impl ReqLLM.Provider
  def decode_stream_event(event, model, provider_state) do
    chunks = ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)

    Enum.reduce(chunks, {[], provider_state}, fn chunk, {acc, state} ->
      case chunk.type do
        :content ->
          {emitted, new_state} = consume_stream_delta(state, chunk.text)
          {acc ++ emitted, new_state}

        _ ->
          {acc ++ [chunk], state}
      end
    end)
  end

  @doc """
  Flush any remaining buffered content when stream ends.

  Emits final thinking or text chunk if buffer is non-empty.
  """
  @impl ReqLLM.Provider
  def flush_stream_state(_model, %{mode: mode, buffer: buffer} = state) do
    chunks =
      case {mode, buffer} do
        {_, ""} -> []
        {:text, b} -> [ReqLLM.StreamChunk.text(b)]
        {:thinking, b} -> [ReqLLM.StreamChunk.thinking(b)]
      end

    {chunks, %{state | buffer: ""}}
  end

  @doc """
  Custom response decoding that normalizes `<think>` tags into reasoning content parts.

  Some Groq models (qwen/qwen3-32b, deepseek-r1-distill-llama-70b) embed thinking content
  within `<think>...</think>` tags in the message content field. This override normalizes
  those responses to extract thinking content as `:thinking` content parts, matching the
  behavior of models that use separate `delta.reasoning` fields.

  For non-streaming: splits `<think>` blocks from message content into `:thinking` and `:text` parts.
  For streaming: wraps the stream to convert embedded `<think>` sequences in chunks into separate chunks.
  """
  @impl ReqLLM.Provider
  def decode_response({req, %Req.Response{} = resp}) do
    {req, decoded} = ReqLLM.Provider.Defaults.default_decode_response({req, resp})

    case decoded do
      %Req.Response{
        body: %ReqLLM.Response{stream?: false, message: %ReqLLM.Message{} = msg, context: ctx} = r
      } ->
        new_msg = normalize_msg_think_tags(msg)
        new_ctx = %{ctx | messages: List.replace_at(ctx.messages, -1, new_msg)}
        {req, %{decoded | body: %{r | message: new_msg, context: new_ctx}}}

      %Req.Response{} ->
        {req, decoded}

      _ ->
        {req, decoded}
    end
  end

  defp normalize_msg_think_tags(%ReqLLM.Message{content: parts} = msg) when is_list(parts) do
    new_parts =
      parts
      |> Enum.flat_map(fn
        %{type: :text, text: t} when is_binary(t) -> split_think_blocks(t)
        other -> [other]
      end)
      |> merge_adjacent_same_type()

    %{msg | content: new_parts}
  end

  defp split_think_blocks(text) when is_binary(text) do
    do_split(text, :text, [])
    |> Enum.reverse()
  end

  defp do_split("", _mode, acc), do: acc

  defp do_split(text, :text, acc) do
    case :binary.match(text, "<think>") do
      :nomatch ->
        prepend_if_nonempty(acc, {:text, text})

      {pos, 7} ->
        pre = binary_part(text, 0, pos)
        rest = binary_part(text, pos + 7, byte_size(text) - pos - 7)
        acc = prepend_if_nonempty(acc, {:text, pre})
        do_split(rest, :thinking, acc)
    end
  end

  defp do_split(text, :thinking, acc) do
    case :binary.match(text, "</think>") do
      :nomatch ->
        prepend_if_nonempty(acc, {:thinking, text})

      {pos, 8} ->
        inner = binary_part(text, 0, pos)
        rest = binary_part(text, pos + 8, byte_size(text) - pos - 8)
        acc = prepend_if_nonempty(acc, {:thinking, inner})
        do_split(rest, :text, acc)
    end
  end

  defp prepend_if_nonempty(acc, {_type, ""}), do: acc
  defp prepend_if_nonempty(acc, {:text, t}), do: [%{type: :text, text: t} | acc]
  defp prepend_if_nonempty(acc, {:thinking, t}), do: [%{type: :thinking, text: t} | acc]

  defp merge_adjacent_same_type(parts) do
    Enum.reduce(parts, [], fn part, acc ->
      case {acc, part} do
        {[%{type: t, text: a} = prev | rest], %{type: t, text: b}} ->
          [%{prev | text: a <> b} | rest]

        _ ->
          [part | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp consume_stream_delta(%{buffer: buf} = st, delta) do
    buf = buf <> (delta || "")
    consume_complete_segments(%{st | buffer: buf})
  end

  defp consume_complete_segments(%{mode: :text, buffer: buf} = st) do
    case :binary.match(buf, "<think>") do
      :nomatch ->
        if byte_size(buf) > 6 do
          take = find_safe_split_point(buf, byte_size(buf) - 6)
          emit = binary_part(buf, 0, take)
          keep = binary_part(buf, take, byte_size(buf) - take)
          {[ReqLLM.StreamChunk.text(emit)], %{st | buffer: keep}}
        else
          {[], st}
        end

      {pos, 7} ->
        pre = binary_part(buf, 0, pos)
        rest = binary_part(buf, pos + 7, byte_size(buf) - pos - 7)
        emits = if pre == "", do: [], else: [ReqLLM.StreamChunk.text(pre)]
        {more, st2} = consume_complete_segments(%{mode: :thinking, buffer: rest})
        {emits ++ more, st2}
    end
  end

  defp consume_complete_segments(%{mode: :thinking, buffer: buf} = st) do
    case :binary.match(buf, "</think>") do
      :nomatch ->
        if byte_size(buf) > 7 do
          take = find_safe_split_point(buf, byte_size(buf) - 7)
          emit = binary_part(buf, 0, take)
          keep = binary_part(buf, take, byte_size(buf) - take)
          {[ReqLLM.StreamChunk.thinking(emit)], %{st | buffer: keep}}
        else
          {[], st}
        end

      {pos, 8} ->
        inner = binary_part(buf, 0, pos)
        rest = binary_part(buf, pos + 8, byte_size(buf) - pos - 8)
        emits = if inner == "", do: [], else: [ReqLLM.StreamChunk.thinking(inner)]
        {more, st2} = consume_complete_segments(%{mode: :text, buffer: rest})
        {emits ++ more, st2}
    end
  end

  defp find_safe_split_point(_binary, pos) when pos <= 0, do: 0
  defp find_safe_split_point(binary, pos) when pos >= byte_size(binary), do: byte_size(binary)

  defp find_safe_split_point(binary, pos) do
    case :binary.at(binary, pos) do
      byte when byte < 128 ->
        pos

      byte when byte >= 192 ->
        pos

      _continuation_byte ->
        find_safe_split_point(binary, pos - 1)
    end
  end
end
