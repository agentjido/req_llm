defmodule ReqLLM.ToolCallIdCompat do
  @moduledoc """
  Tool call ID compatibility helpers for cross-provider conversations.

  This module normalizes tool call identifiers for providers with stricter
  requirements while preserving passthrough behavior for OpenAI-compatible APIs.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.ToolCall

  @default_invalid_chars_regex ~r/[^A-Za-z0-9_-]/

  @type mode :: :passthrough | :sanitize | :strict | :drop

  @type policy :: %{
          optional(:mode) => mode(),
          optional(:invalid_chars_regex) => Regex.t(),
          optional(:max_length) => pos_integer(),
          optional(:enforce_turn_boundary) => boolean(),
          optional(:drop_function_call_ids) => boolean()
        }

  @spec apply_context(module(), atom(), LLMDB.Model.t() | map(), Context.t(), keyword() | map()) ::
          Context.t()
  def apply_context(provider_mod, operation, model, %Context{} = context, opts)
      when is_atom(provider_mod) do
    provider_policy = provider_policy(provider_mod, operation, model, opts)
    apply_context_with_policy(context, provider_policy, opts)
  end

  @spec apply_context_with_policy(Context.t(), policy() | keyword(), keyword() | map()) ::
          Context.t()
  def apply_context_with_policy(%Context{} = context, policy, opts \\ []) do
    resolved_policy =
      policy
      |> normalize_policy()
      |> override_mode(fetch_compat_mode(opts))

    maybe_validate_turn_boundary(context, resolved_policy)

    case resolved_policy.mode do
      :passthrough ->
        context

      :drop ->
        context

      :strict ->
        validate_all_ids!(context, resolved_policy)
        context

      :sanitize ->
        sanitize_context(context, resolved_policy)
    end
  end

  @spec apply_body(module(), atom(), LLMDB.Model.t() | map(), map(), keyword() | map()) :: map()
  def apply_body(provider_mod, operation, model, body, opts)
      when is_atom(provider_mod) and is_map(body) do
    provider_policy = provider_policy(provider_mod, operation, model, opts)
    apply_body_with_policy(body, provider_policy, opts)
  end

  @spec apply_body_with_policy(map(), policy() | keyword(), keyword() | map()) :: map()
  def apply_body_with_policy(body, policy, opts \\ []) when is_map(body) do
    resolved_policy =
      policy
      |> normalize_policy()
      |> override_mode(fetch_compat_mode(opts))

    if resolved_policy.drop_function_call_ids do
      drop_function_call_ids(body)
    else
      body
    end
  end

  defp provider_policy(provider_mod, operation, model, opts) do
    if function_exported?(provider_mod, :tool_call_id_policy, 3) do
      provider_mod.tool_call_id_policy(operation, model, opts)
    else
      %{mode: :passthrough}
    end
  end

  defp normalize_policy(policy) when is_list(policy), do: normalize_policy(Map.new(policy))

  defp normalize_policy(policy) when is_map(policy) do
    %{
      mode: Map.get(policy, :mode, :passthrough),
      invalid_chars_regex: Map.get(policy, :invalid_chars_regex, @default_invalid_chars_regex),
      max_length: Map.get(policy, :max_length),
      enforce_turn_boundary: Map.get(policy, :enforce_turn_boundary, false),
      drop_function_call_ids: Map.get(policy, :drop_function_call_ids, false)
    }
  end

  defp override_mode(policy, :auto), do: policy
  defp override_mode(policy, nil), do: policy
  defp override_mode(policy, mode), do: %{policy | mode: mode}

  defp fetch_compat_mode(opts) when is_list(opts),
    do: Keyword.get(opts, :tool_call_id_compat, :auto)

  defp fetch_compat_mode(opts) when is_map(opts), do: Map.get(opts, :tool_call_id_compat, :auto)
  defp fetch_compat_mode(_opts), do: :auto

  defp maybe_validate_turn_boundary(%Context{} = context, %{enforce_turn_boundary: true}) do
    if unresolved_tool_calls?(context.messages) do
      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter:
                "Context ends with unresolved tool calls. Switch providers only after appending tool results for all assistant tool calls."
            )
    end
  end

  defp maybe_validate_turn_boundary(_context, _policy), do: :ok

  defp unresolved_tool_calls?(messages) do
    pending =
      Enum.reduce(messages, MapSet.new(), fn message, acc ->
        acc
        |> add_pending_tool_calls(message)
        |> resolve_tool_result(message)
      end)

    not MapSet.equal?(pending, MapSet.new())
  end

  defp add_pending_tool_calls(acc, %Message{role: :assistant} = message) do
    call_ids = tool_call_ids_for_message(message)

    Enum.reduce(call_ids, acc, fn
      id, set when is_binary(id) and id != "" -> MapSet.put(set, id)
      _id, set -> set
    end)
  end

  defp add_pending_tool_calls(acc, _message), do: acc

  defp resolve_tool_result(acc, %Message{role: :tool, tool_call_id: id})
       when is_binary(id) and id != "" do
    MapSet.delete(acc, id)
  end

  defp resolve_tool_result(acc, _message), do: acc

  defp tool_call_ids_for_message(%Message{} = message) do
    from_tool_calls =
      message.tool_calls
      |> List.wrap()
      |> Enum.map(&tool_call_id/1)

    from_content_parts =
      message.content
      |> List.wrap()
      |> Enum.flat_map(&content_part_tool_call_ids/1)

    from_tool_calls ++ from_content_parts
  end

  defp validate_all_ids!(%Context{messages: messages}, policy) do
    ids =
      messages
      |> Enum.flat_map(&message_ids/1)
      |> Enum.uniq()

    invalid_ids = Enum.filter(ids, &(not valid_id?(&1, policy)))

    if invalid_ids != [] do
      rendered = Enum.map_join(invalid_ids, ", ", &inspect/1)

      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter: "tool_call_id values incompatible with provider policy: #{rendered}"
            )
    end
  end

  defp sanitize_context(%Context{messages: messages} = context, policy) do
    {updated_messages, _state} =
      Enum.map_reduce(messages, init_state(), fn message, state ->
        sanitize_message(message, state, policy)
      end)

    %{context | messages: updated_messages}
  end

  defp init_state do
    %{mapping: %{}, used: MapSet.new(), counters: %{}}
  end

  defp sanitize_message(%Message{} = message, state, policy) do
    {tool_calls, state} = sanitize_message_tool_calls(message.tool_calls, state, policy)
    {tool_call_id, state} = sanitize_optional_id(message.tool_call_id, state, policy)
    {content, state} = sanitize_content_parts(message.content, state, policy)

    {%{message | tool_calls: tool_calls, tool_call_id: tool_call_id, content: content}, state}
  end

  defp sanitize_message_tool_calls(nil, state, _policy), do: {nil, state}

  defp sanitize_message_tool_calls(tool_calls, state, policy) when is_list(tool_calls) do
    Enum.map_reduce(tool_calls, state, fn tool_call, acc ->
      sanitize_tool_call(tool_call, acc, policy)
    end)
  end

  defp sanitize_message_tool_calls(other, state, _policy), do: {other, state}

  defp sanitize_tool_call(%ToolCall{id: id} = tool_call, state, policy) do
    {updated_id, state} = sanitize_optional_id(id, state, policy)
    {%{tool_call | id: updated_id}, state}
  end

  defp sanitize_tool_call(tool_call, state, policy) when is_map(tool_call) do
    {tool_call, state} = sanitize_map_key(tool_call, :id, state, policy)
    {tool_call, state} = sanitize_map_key(tool_call, "id", state, policy)
    sanitize_map_tool_id(tool_call, state, policy)
  end

  defp sanitize_tool_call(other, state, _policy), do: {other, state}

  defp sanitize_content_parts(content, state, policy) when is_list(content) do
    Enum.map_reduce(content, state, fn part, acc ->
      sanitize_content_part(part, acc, policy)
    end)
  end

  defp sanitize_content_parts(content, state, _policy), do: {content, state}

  defp sanitize_content_part(part, state, policy) when is_map(part) do
    {part, state} = sanitize_map_tool_id(part, state, policy)
    {part, state} = sanitize_part_metadata_tool_id(part, state, policy)
    {part, state}
  end

  defp sanitize_content_part(part, state, _policy), do: {part, state}

  defp sanitize_part_metadata_tool_id(part, state, policy) do
    part_type = map_get(part, :type) || map_get(part, "type")

    if part_type in [:tool_call, "tool_call"] do
      metadata = map_get(part, :metadata) || map_get(part, "metadata")
      metadata_key = if Map.has_key?(part, "metadata"), do: "metadata", else: :metadata

      case metadata do
        value when is_map(value) ->
          {updated_metadata, state} = sanitize_map_tool_id(value, state, policy)
          {map_put(part, metadata_key, updated_metadata), state}

        _ ->
          {part, state}
      end
    else
      {part, state}
    end
  end

  defp sanitize_map_tool_id(map, state, policy) do
    {map, state} = sanitize_map_key(map, :tool_call_id, state, policy)
    {map, state} = sanitize_map_key(map, "tool_call_id", state, policy)

    type = map_get(map, :type) || map_get(map, "type")

    if type in [:tool_call, "tool_call"] do
      {map, state} = sanitize_map_key(map, :id, state, policy)
      sanitize_map_key(map, "id", state, policy)
    else
      {map, state}
    end
  end

  defp sanitize_map_key(map, key, state, policy) do
    case map_get(map, key) do
      value when is_binary(value) and value != "" ->
        {updated, state} = sanitize_id(value, state, policy)
        {map_put(map, key, updated), state}

      _ ->
        {map, state}
    end
  end

  defp sanitize_optional_id(nil, state, _policy), do: {nil, state}

  defp sanitize_optional_id(id, state, policy) when is_binary(id) and id != "" do
    sanitize_id(id, state, policy)
  end

  defp sanitize_optional_id(other, state, _policy), do: {other, state}

  defp sanitize_id(id, state, policy) do
    case Map.fetch(state.mapping, id) do
      {:ok, mapped} ->
        {mapped, state}

      :error ->
        base = sanitize_id_base(id, policy)
        {mapped, state} = allocate_unique_id(base, state, policy.max_length)

        state = %{
          state
          | mapping: Map.put(state.mapping, id, mapped),
            used: MapSet.put(state.used, mapped)
        }

        {mapped, state}
    end
  end

  defp sanitize_id_base(id, policy) do
    replaced = Regex.replace(policy.invalid_chars_regex, id, "_")
    limited = enforce_max_length(replaced, policy.max_length)

    if limited == "" do
      enforce_max_length("tool_call", policy.max_length)
    else
      limited
    end
  end

  defp allocate_unique_id(base, state, max_length) do
    if MapSet.member?(state.used, base) do
      next = Map.get(state.counters, base, 1)
      allocate_unique_id(base, next, state, max_length)
    else
      {base, state}
    end
  end

  defp allocate_unique_id(base, counter, state, max_length) do
    suffix = "_" <> Integer.to_string(counter)
    trimmed = trim_for_suffix(base, suffix, max_length)
    candidate = trimmed <> suffix

    if MapSet.member?(state.used, candidate) do
      allocate_unique_id(base, counter + 1, state, max_length)
    else
      updated_state = %{state | counters: Map.put(state.counters, base, counter + 1)}
      {candidate, updated_state}
    end
  end

  defp trim_for_suffix(base, _suffix, nil), do: base

  defp trim_for_suffix(base, suffix, max_length) when is_integer(max_length) and max_length > 0 do
    keep = max(max_length - String.length(suffix), 0)
    String.slice(base, 0, keep)
  end

  defp trim_for_suffix(base, _suffix, _max_length), do: base

  defp enforce_max_length(id, nil), do: id

  defp enforce_max_length(id, max_length) when is_integer(max_length) and max_length > 0 do
    if String.length(id) > max_length do
      String.slice(id, 0, max_length)
    else
      id
    end
  end

  defp enforce_max_length(id, _max_length), do: id

  defp valid_id?(id, policy) when is_binary(id) do
    id != "" and not Regex.match?(policy.invalid_chars_regex, id) and
      within_max_length?(id, policy.max_length)
  end

  defp valid_id?(_id, _policy), do: false

  defp within_max_length?(id, nil), do: id != ""

  defp within_max_length?(id, max_length) when is_integer(max_length) and max_length > 0 do
    String.length(id) <= max_length
  end

  defp within_max_length?(_id, _), do: true

  defp message_ids(%Message{} = message) do
    tool_call_ids =
      message.tool_calls
      |> List.wrap()
      |> Enum.map(&tool_call_id/1)

    tool_result_ids =
      case message.tool_call_id do
        id when is_binary(id) and id != "" -> [id]
        _ -> []
      end

    content_ids =
      message.content
      |> List.wrap()
      |> Enum.flat_map(&content_part_tool_call_ids/1)

    tool_call_ids ++ tool_result_ids ++ content_ids
  end

  defp tool_call_id(%ToolCall{id: id}) when is_binary(id) and id != "", do: id

  defp tool_call_id(tool_call) when is_map(tool_call) do
    case map_get(tool_call, :id) || map_get(tool_call, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp tool_call_id(_), do: nil

  defp content_part_tool_call_ids(part) when is_map(part) do
    direct =
      [map_get(part, :tool_call_id), map_get(part, "tool_call_id")]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    nested =
      case map_get(part, :metadata) || map_get(part, "metadata") do
        metadata when is_map(metadata) ->
          [map_get(metadata, :tool_call_id), map_get(metadata, "tool_call_id")]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        _ ->
          []
      end

    direct ++ nested
  end

  defp content_part_tool_call_ids(_), do: []

  defp map_get(map, key) when is_map_key(map, key), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil

  defp map_put(map, key, value), do: Map.put(map, key, value)

  defp drop_function_call_ids(%{"contents" => contents} = body) when is_list(contents) do
    sanitized_contents =
      Enum.map(contents, fn
        %{"parts" => parts} = content when is_list(parts) ->
          sanitized_parts =
            Enum.map(parts, fn
              %{"functionCall" => function_call} = part when is_map(function_call) ->
                Map.put(part, "functionCall", Map.delete(function_call, "id"))

              other ->
                other
            end)

          Map.put(content, "parts", sanitized_parts)

        other ->
          other
      end)

    Map.put(body, "contents", sanitized_contents)
  end

  defp drop_function_call_ids(body), do: body
end
