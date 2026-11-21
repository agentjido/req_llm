defmodule ReqLLM.Providers.Google.InteractionsAPI.StepHistory do
  @moduledoc false

  alias ReqLLM.Message
  alias ReqLLM.Providers.Google.InteractionsAPI.Helpers

  @spec preserve_interactions_steps(ReqLLM.Response.t(), [map()]) :: ReqLLM.Response.t()
  def preserve_interactions_steps(
        %ReqLLM.Response{message: %Message{} = message} = response,
        [_ | _] = steps
      ) do
    history = %{"steps" => steps, "fingerprint" => message_fingerprint(message)}

    metadata =
      (message.metadata || %{})
      |> Map.put(Helpers.interactions_metadata_key(), history)
      |> maybe_put_new_interaction_id(response.id)

    %{response | message: %{message | metadata: metadata}}
  end

  def preserve_interactions_steps(response, _steps), do: response

  defp maybe_put_new_interaction_id(metadata, id) when is_binary(id) and id != "" do
    Map.put_new(metadata, "interaction_id", id)
  end

  defp maybe_put_new_interaction_id(metadata, _id), do: metadata

  @spec verified_interactions_steps(Message.t() | map()) :: [map()] | nil
  def verified_interactions_steps(%Message{role: :assistant, metadata: metadata} = message)
      when is_map(metadata) do
    with %{"steps" => [_ | _] = steps, "fingerprint" => stored} when is_binary(stored) <-
           Map.get(metadata, Helpers.interactions_metadata_key()),
         ^stored <- message_fingerprint(message) do
      steps
    else
      _ -> nil
    end
  end

  def verified_interactions_steps(_message), do: nil

  def slice_latest_turn_steps(steps) when is_list(steps) do
    {turn_steps, _resolved_call_ids} = slice_latest_turn_with_resolved(steps)
    Enum.map(turn_steps, fn {step, _idx} -> step end)
  end

  def slice_latest_turn_steps(_), do: []

  def slice_latest_turn_steps_with_index(steps) when is_list(steps) do
    {turn_steps, _resolved_call_ids} = slice_latest_turn_with_resolved(steps)
    turn_steps
  end

  def slice_latest_turn_with_resolved(steps) when is_list(steps) do
    indexed = Enum.with_index(steps)

    since_user =
      case Enum.reduce(indexed, nil, fn
             {%{"type" => "user_input"}, idx}, _last -> idx
             _, last -> last
           end) do
        nil -> indexed
        last_user_idx -> Enum.drop(indexed, last_user_idx + 1)
      end

    last_fr_pos =
      since_user
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {{%{"type" => "function_result"}, _orig_idx}, pos}, _last -> pos
        _, last -> last
      end)

    case last_fr_pos do
      nil ->
        {since_user, MapSet.new()}

      pos ->
        after_fr = Enum.drop(since_user, pos + 1)

        if after_fr != [] do
          {after_fr, MapSet.new()}
        else
          slice_trailing_tool_results_turn(since_user)
        end
    end
  end

  def slice_latest_turn_with_resolved(_), do: {[], MapSet.new()}

  defp slice_trailing_tool_results_turn(since_user) do
    {rev_trailing_frs, rev_prefix} =
      since_user
      |> Enum.reverse()
      |> Enum.split_while(fn {step, _idx} -> Map.get(step, "type") == "function_result" end)

    trailing_fr_call_ids =
      Enum.reduce(rev_trailing_frs, MapSet.new(), fn
        {%{"call_id" => call_id}, _idx}, acc when is_binary(call_id) and call_id != "" ->
          MapSet.put(acc, call_id)

        _, acc ->
          acc
      end)

    preceding_turn =
      rev_prefix
      |> Enum.take_while(fn {step, _idx} ->
        Map.get(step, "type") not in ["user_input", "function_result"]
      end)
      |> Enum.reverse()

    unresolved_fc? =
      Enum.any?(preceding_turn, fn {step, _idx} ->
        Map.get(step, "type") == "function_call" and
          not MapSet.member?(trailing_fr_call_ids, Map.get(step, "id"))
      end)

    if unresolved_fc? do
      {preceding_turn, trailing_fr_call_ids}
    else
      {[], trailing_fr_call_ids}
    end
  end

  def extract_resolved_call_ids(steps) when is_list(steps) do
    {_turn_steps, resolved_call_ids} = slice_latest_turn_with_resolved(steps)
    resolved_call_ids
  end

  def extract_resolved_call_ids(_), do: MapSet.new()

  def select_stateful_delta(chat_messages, prev_id) do
    case find_matching_assistant_index(chat_messages, prev_id) do
      idx when is_integer(idx) ->
        Enum.drop(chat_messages, idx + 1)

      nil ->
        take_trailing_turn_delta(chat_messages)
    end
  end

  defp find_matching_assistant_index(messages, prev_id) do
    if Helpers.non_empty_binary?(prev_id) do
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%Message{role: :assistant, metadata: meta}, idx} when is_map(meta) ->
          if Map.get(meta, :response_id) == prev_id or
               Map.get(meta, "response_id") == prev_id or
               Map.get(meta, :interaction_id) == prev_id or
               Map.get(meta, "interaction_id") == prev_id,
             do: idx

        _ ->
          nil
      end)
    end
  end

  defp take_trailing_turn_delta([]), do: []

  defp take_trailing_turn_delta(messages) do
    case List.last(messages) do
      %Message{role: :assistant} ->
        []

      _ ->
        messages
        |> Enum.reverse()
        |> Enum.take_while(&(&1.role != :assistant))
        |> Enum.reverse()
    end
  end

  defp message_fingerprint(message) do
    normalized =
      normalize_for_fingerprint([message.content, message.tool_calls, message.reasoning_details])

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(normalized, [:deterministic]))
    |> Base.encode64()
  end

  defp normalize_for_fingerprint(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_for_fingerprint()
  end

  defp normalize_for_fingerprint(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {normalize_fingerprint_key(k), normalize_for_fingerprint(v)}
    end)
  end

  defp normalize_for_fingerprint(list) when is_list(list) do
    Enum.map(list, &normalize_for_fingerprint/1)
  end

  defp normalize_for_fingerprint(tuple) when is_tuple(tuple) do
    {"__tuple__", tuple |> Tuple.to_list() |> Enum.map(&normalize_for_fingerprint/1)}
  end

  defp normalize_for_fingerprint(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      {"__bin__", :crypto.hash(:sha256, bin)}
    end
  end

  defp normalize_for_fingerprint(val)
       when is_nil(val) or is_boolean(val) or is_number(val),
       do: val

  defp normalize_for_fingerprint(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_for_fingerprint(other), do: inspect(other)

  defp normalize_fingerprint_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_fingerprint_key(k) when is_binary(k), do: k
  defp normalize_fingerprint_key(k), do: inspect(k)
end
