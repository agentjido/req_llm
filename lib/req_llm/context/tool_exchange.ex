defmodule ReqLLM.Context.ToolExchange do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.Error.Validation.Error
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.ToolCall

  @spec append(Context.t(), Message.t() | Response.t(), [Message.t()]) ::
          {:ok, Context.t()} | {:error, Error.t()}
  def append(%Context{} = context, source, results) do
    with {:ok, assistant} <- assistant(source),
         {:ok, calls} <- calls(assistant),
         {:ok, ordered_results} <- results(calls, results),
         {:ok, context} <- append_assistant(context, source, assistant) do
      {:ok, Context.append(context, ordered_results)}
    end
  end

  defp assistant(%Response{message: %Message{} = message}), do: validate_assistant(message)
  defp assistant(%Message{} = message), do: validate_assistant(message)

  defp assistant(_source) do
    error(
      :invalid_assistant,
      "Tool exchange requires an assistant message or response with an assistant message"
    )
  end

  defp validate_assistant(%Message{role: :assistant} = message) do
    if Message.valid?(message) do
      {:ok, message}
    else
      error(:invalid_assistant, "Tool exchange assistant message is invalid")
    end
  end

  defp validate_assistant(_message) do
    error(:invalid_assistant, "Tool exchange message must have role :assistant")
  end

  defp calls(%Message{tool_calls: tool_calls}) when is_list(tool_calls) do
    invalid_index = Enum.find_index(tool_calls, &(not valid_call?(&1)))

    cond do
      tool_calls == [] ->
        error(:missing_tool_calls, "Tool exchange assistant message has no tool calls")

      invalid_index != nil ->
        error(
          :invalid_tool_calls,
          "Tool exchange contains an invalid canonical tool call",
          index: invalid_index
        )

      true ->
        normalize_calls(tool_calls)
    end
  end

  defp calls(_assistant) do
    error(
      :invalid_tool_calls,
      "Tool exchange assistant message must contain a list of tool calls"
    )
  end

  defp results(_calls, results) when not is_list(results) do
    error(:invalid_tool_results, "Tool exchange results must be a list")
  end

  defp results(calls, results) do
    invalid_index = Enum.find_index(results, &(not valid_result?(&1)))

    if invalid_index == nil do
      match_results(calls, results)
    else
      error(
        :invalid_tool_results,
        "Tool exchange contains an invalid canonical tool-result message",
        index: invalid_index
      )
    end
  end

  defp match_results(calls, results) do
    call_ids = Enum.map(calls, & &1.id)
    result_ids = Enum.map(results, & &1.tool_call_id)
    duplicates = duplicates(result_ids)
    unknown = result_ids -- call_ids
    missing = call_ids -- result_ids
    results_by_id = Map.new(results, &{&1.tool_call_id, &1})
    mismatches = mismatches(calls, results_by_id)

    cond do
      duplicates != [] ->
        error(:duplicate_tool_results, "Tool exchange contains duplicate tool-result IDs",
          ids: duplicates
        )

      unknown != [] ->
        error(:unknown_tool_results, "Tool exchange contains results for unknown tool-call IDs",
          ids: unknown
        )

      missing != [] ->
        error(:missing_tool_results, "Tool exchange is missing results for assistant tool calls",
          ids: missing
        )

      mismatches != [] ->
        error(
          :mismatched_tool_results,
          "Tool exchange result names do not match their assistant tool calls",
          mismatches: mismatches
        )

      true ->
        {:ok, ordered_results(calls, results_by_id)}
    end
  end

  defp provider_executed_call?(call), do: ToolCall.builtin?(call)

  defp valid_call?(%ToolCall{
         type: "function",
         id: id,
         function: %{name: name, arguments: arguments}
       }) do
    non_empty_string?(id) and non_empty_string?(name) and is_binary(arguments)
  end

  defp valid_call?(_call), do: false

  defp call_identity(%ToolCall{id: id, function: %{name: name}}) do
    %{id: id, name: name}
  end

  defp normalize_calls(calls) do
    normalized = Enum.map(calls, &call_identity/1)
    duplicate_ids = normalized |> Enum.map(& &1.id) |> duplicates()

    if duplicate_ids == [] do
      application_calls =
        calls
        |> Enum.reject(&provider_executed_call?/1)
        |> Enum.map(&call_identity/1)

      {:ok, application_calls}
    else
      error(
        :duplicate_tool_calls,
        "Tool exchange contains duplicate assistant tool-call IDs",
        ids: duplicate_ids
      )
    end
  end

  defp valid_result?(%Message{
         role: :tool,
         tool_call_id: id,
         name: name,
         content: content,
         metadata: metadata
       }) do
    non_empty_string?(id) and valid_optional_name?(name) and valid_content?(content) and
      is_map(metadata)
  end

  defp valid_result?(_result), do: false

  defp valid_optional_name?(nil), do: true
  defp valid_optional_name?(name), do: non_empty_string?(name)

  defp valid_content?(content) when is_list(content),
    do: Enum.all?(content, &ContentPart.valid?/1)

  defp valid_content?(_content), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp mismatches(calls, results_by_id) do
    Enum.flat_map(calls, fn call ->
      case Map.get(results_by_id, call.id) do
        %Message{name: nil} -> []
        %Message{name: name} when name == call.name -> []
        %Message{name: name} -> [%{id: call.id, expected: call.name, actual: name}]
        nil -> []
      end
    end)
  end

  defp ordered_results(calls, results_by_id) do
    Enum.map(calls, fn call ->
      case Map.fetch!(results_by_id, call.id) do
        %Message{name: nil} = message -> %{message | name: call.name}
        %Message{} = message -> message
      end
    end)
  end

  defp duplicates(ids), do: (ids -- Enum.uniq(ids)) |> Enum.uniq()

  defp append_assistant(%Context{messages: messages} = context, source, assistant) do
    case List.last(messages) do
      ^assistant ->
        {:ok, context}

      last_message ->
        if pending_calls?(last_message) do
          error(
            :pending_tool_calls,
            "Context already ends with a different unresolved assistant tool-call message"
          )
        else
          {:ok, append_source(context, source, assistant)}
        end
    end
  end

  defp append_source(context, %Response{} = response, _assistant) do
    Context.merge_response(context, response).context
  end

  defp append_source(context, _source, assistant), do: Context.append(context, assistant)

  defp pending_calls?(%Message{role: :assistant, tool_calls: tool_calls})
       when is_list(tool_calls) do
    Enum.any?(tool_calls, &(not provider_executed_call?(&1)))
  end

  defp pending_calls?(_message), do: false

  defp error(kind, reason, details \\ []) do
    {:error,
     Error.exception(
       tag: :tool_context_continuation,
       reason: reason,
       context: [kind: kind] ++ details
     )}
  end
end
