defmodule ReqLLM.Providers.Google.ResponseBuilder do
  @moduledoc """
  Google/Gemini-specific ResponseBuilder implementation.

  Handles Google's specific requirements:
  - Detects `functionCall` in parts to set correct finish_reason
  - Google returns "STOP" even when function calls are made
  - Extracts reasoning_details with thought signatures from thinking chunks
  - Preserves text thought signatures and their original part boundaries
  - Carries the raw `finishReason` and `finishMessage` into `provider_meta`,
    as the non-streaming path does

  This fixes bug #271 where streaming responses with tool calls
  had `:stop` finish_reason instead of `:tool_calls`.
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.ToolHistory
  alias ReqLLM.StreamChunk

  @impl true
  def build_response(chunks, metadata, opts) do
    has_tool_calls? = Enum.any?(chunks, &tool_call_chunk?/1)

    metadata =
      if has_tool_calls? and finish_reason_is_stop?(metadata[:finish_reason]) do
        Map.put(metadata, :finish_reason, :tool_calls)
      else
        metadata
      end

    normalized_chunks = preserve_signed_text_parts(chunks)

    with {:ok, response} <-
           DefaultBuilder.build_response(normalized_chunks, metadata, opts) do
      response = maybe_preserve_interactions_content_order(response, normalized_chunks, metadata)
      reasoning_details = extract_google_reasoning_details(chunks)
      response_with_reasoning = attach_reasoning_details(response, reasoning_details)

      response =
        response_with_reasoning
        |> preserve_tool_history(metadata, opts)
        |> maybe_put_metadata_object(metadata)
        |> maybe_put_metadata_error(metadata)
        |> maybe_put_response_model(metadata)

      {:ok, put_raw_finish(response, metadata)}
    end
  end

  defp preserve_tool_history(response, %{google_tool_history: parts}, opts) do
    ReqLLM.Context.merge_response(
      Keyword.fetch!(opts, :context),
      ToolHistory.preserve(response, parts)
    )
  end

  defp preserve_tool_history(response, %{google_interactions_steps: steps}, opts) do
    preserved = InteractionsAPI.preserve_interactions_steps(response, steps)

    case Keyword.get(opts, :context) do
      %ReqLLM.Context{} = context -> ReqLLM.Context.merge_response(context, preserved)
      _ -> preserved
    end
  end

  defp preserve_tool_history(response, _metadata, _opts), do: response

  defp maybe_put_metadata_object(%ReqLLM.Response{} = response, %{object: object})
       when not is_nil(object) do
    %{response | object: object}
  end

  defp maybe_put_metadata_object(%ReqLLM.Response{} = response, %{
         google_interactions_steps: _steps
       }) do
    %{response | object: nil}
  end

  defp maybe_put_metadata_object(response, _metadata), do: response

  defp maybe_put_metadata_error(%ReqLLM.Response{error: nil} = response, %{error: error})
       when not is_nil(error) do
    %{response | error: error}
  end

  defp maybe_put_metadata_error(response, _metadata), do: response

  defp maybe_put_response_model(%ReqLLM.Response{} = response, %{response_model: response_model})
       when is_binary(response_model) and response_model != "" do
    %{response | model: response_model}
  end

  defp maybe_put_response_model(response, _metadata), do: response

  defp put_raw_finish(%ReqLLM.Response{} = response, metadata) do
    raw =
      metadata
      |> Map.take([:finish_reason_raw, :finish_message])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    %{response | provider_meta: Map.merge(response.provider_meta, raw)}
  end

  defp preserve_signed_text_parts(chunks) do
    Enum.map(chunks, fn
      %StreamChunk{type: :content, text: text, metadata: %{thought_signature: signature}}
      when is_binary(signature) and signature != "" ->
        StreamChunk.content_part(%ReqLLM.Message.ContentPart{
          type: :text,
          text: text,
          metadata: %{thought_signature: signature}
        })

      chunk ->
        chunk
    end)
  end

  defp finish_reason_is_stop?(:stop), do: true
  defp finish_reason_is_stop?("stop"), do: true
  defp finish_reason_is_stop?(_), do: false

  defp tool_call_chunk?(%StreamChunk{type: :tool_call}), do: true
  defp tool_call_chunk?(_), do: false

  defp extract_google_reasoning_details(chunks) do
    {entries, rev_keys, _seq} =
      chunks
      |> Enum.filter(&thinking_chunk?/1)
      |> Enum.reduce({%{}, [], 0}, &accumulate_thinking_chunk/2)

    rev_keys
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {key, index} ->
      entry = Map.fetch!(entries, key)

      %ReqLLM.Message.ReasoningDetails{
        text: IO.iodata_to_binary(entry.text_iodata),
        signature: entry.signature,
        encrypted?: entry.signature != nil,
        provider: :google,
        format: entry.format,
        index: index,
        provider_data: entry.provider_data
      }
    end)
  end

  defp accumulate_thinking_chunk(chunk, {entries, rev_keys, seq}) do
    meta = chunk.metadata || %{}
    text = chunk.text || ""
    signature = Map.get(meta, :signature)
    format = Map.get(meta, :format, "google-gemini-v1")
    step_index = Map.get(meta, :step_index)

    provider_data =
      meta
      |> Map.get(:provider_data, %{"thought" => true})
      |> maybe_put_thought_step_index(format, step_index)

    {key, next_seq} =
      case {format, step_index} do
        {"google-interactions-v1", idx} when is_integer(idx) ->
          {{:interactions_step, idx}, seq}

        _ ->
          {{:chunk, seq}, seq + 1}
      end

    case Map.fetch(entries, key) do
      {:ok, existing} ->
        merged_provider_data =
          meta
          |> Map.get(:provider_data, existing.provider_data)
          |> maybe_put_thought_step_index(format, step_index)

        updated = %{
          existing
          | text_iodata: [existing.text_iodata, text],
            signature: signature || existing.signature,
            provider_data: merged_provider_data
        }

        {Map.put(entries, key, updated), rev_keys, next_seq}

      :error ->
        created = %{
          text_iodata: [text],
          signature: signature,
          format: format,
          provider_data: provider_data
        }

        {Map.put(entries, key, created), [key | rev_keys], next_seq}
    end
  end

  defp maybe_put_thought_step_index(provider_data, "google-interactions-v1", step_index)
       when is_map(provider_data) and is_integer(step_index) do
    Map.put_new(provider_data, "step_index", step_index)
  end

  defp maybe_put_thought_step_index(provider_data, _format, _step_index), do: provider_data

  defp thinking_chunk?(%StreamChunk{type: :thinking}), do: true
  defp thinking_chunk?(_), do: false

  defp maybe_preserve_interactions_content_order(
         %ReqLLM.Response{message: %ReqLLM.Message{} = message} = response,
         chunks,
         %{google_interactions_steps: _steps}
       ) do
    ordered = build_ordered_interactions_content(chunks)

    if ordered == message.content do
      response
    else
      updated_message = %{message | content: ordered}
      updated_context = replace_last_context_message(response.context, updated_message)
      %{response | message: updated_message, context: updated_context}
    end
  end

  defp maybe_preserve_interactions_content_order(response, _chunks, _metadata), do: response

  defp build_ordered_interactions_content(chunks) do
    chunks
    |> Enum.reduce([], fn
      %StreamChunk{type: :content, text: text}, acc when is_binary(text) and text != "" ->
        case acc do
          [{:text, rev_iodata} | rest] -> [{:text, [text | rev_iodata]} | rest]
          _ -> [{:text, [text]} | acc]
        end

      %StreamChunk{type: :thinking, text: text, metadata: meta}, acc
      when is_binary(text) and text != "" ->
        step_index = if is_map(meta), do: Map.get(meta, :step_index), else: nil

        case acc do
          [{:thinking, ^step_index, rev_iodata} | rest] ->
            [{:thinking, step_index, [text | rev_iodata]} | rest]

          _ ->
            [{:thinking, step_index, [text]} | acc]
        end

      %StreamChunk{type: :content_part, metadata: %{stream_only?: true}}, acc ->
        acc

      %StreamChunk{type: :content_part, content_part: %ReqLLM.Message.ContentPart{} = part},
      acc ->
        [{:part, part} | acc]

      _chunk, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:text, rev_iodata} ->
        %ReqLLM.Message.ContentPart{
          type: :text,
          text: rev_iodata |> Enum.reverse() |> IO.iodata_to_binary()
        }

      {:thinking, _step_index, rev_iodata} ->
        %ReqLLM.Message.ContentPart{
          type: :thinking,
          text: rev_iodata |> Enum.reverse() |> IO.iodata_to_binary()
        }

      {:part, part} ->
        part
    end)
  end

  defp attach_reasoning_details(response, []), do: response

  defp attach_reasoning_details(%ReqLLM.Response{message: nil} = response, _details), do: response

  defp attach_reasoning_details(
         %ReqLLM.Response{message: %ReqLLM.Message{} = message} = response,
         details
       ) do
    updated_message = %{message | reasoning_details: details}
    updated_context = replace_last_context_message(response.context, updated_message)
    %{response | message: updated_message, context: updated_context}
  end

  defp replace_last_context_message(context, updated_message) do
    case context.messages do
      [] ->
        %{context | messages: [updated_message]}

      msgs ->
        {init, [last]} = Enum.split(msgs, -1)

        if is_struct(last, ReqLLM.Message) and last.role == updated_message.role do
          %{context | messages: init ++ [updated_message]}
        else
          context
        end
    end
  end
end
