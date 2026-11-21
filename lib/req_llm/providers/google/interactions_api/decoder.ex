defmodule ReqLLM.Providers.Google.InteractionsAPI.Decoder do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Google.InteractionsAPI.Helpers
  alias ReqLLM.Providers.Google.InteractionsAPI.StepHistory
  alias ReqLLM.Providers.Google.ResponseBuilder
  alias ReqLLM.StreamChunk
  alias ReqLLM.Usage.Tool, as: ToolUsage

  @interactions_usage_keys ~w(
    total_input_tokens
    total_output_tokens
    total_thought_tokens
    total_cached_tokens
    total_tool_use_tokens
    total_tokens
    grounding_tool_count
  )

  @builtin_call_tool_keys %{
    "file_search_call" => :file_search,
    "code_execution_call" => :code_execution,
    "url_context_call" => :url_context,
    "google_maps_call" => :google_maps,
    "computer_use_call" => :computer_use,
    "mcp_server_tool_call" => :mcp_server
  }

  @grounding_tool_keys %{
    "google_search" => :web_search,
    "google_search_retrieval" => :web_search,
    "web_search" => :web_search,
    "google_maps" => :google_maps,
    "url_context" => :url_context,
    "url_context_metadata" => :url_context,
    "file_search" => :file_search,
    "code_execution" => :code_execution,
    "computer_use" => :computer_use,
    "mcp_server" => :mcp_server
  }

  @status_finish_reasons %{
    "completed" => :stop,
    "requires_action" => :tool_calls,
    "incomplete" => :incomplete,
    "requires_continuation" => :incomplete,
    "budget_exceeded" => :length,
    "cancelled" => :cancelled,
    "failed" => :error,
    "in_progress" => nil,
    "queued" => nil
  }

  def decode_interaction_body(
        %{} = body,
        %LLMDB.Model{} = model,
        %Context{} = context,
        opts \\ []
      ) do
    steps = List.wrap(body["steps"])

    {chunks, assistant_steps, builtin_tools, resolved_call_ids} =
      decode_steps_to_chunks(steps, body["id"])

    finish_reason = resolve_finish_reason(body["status"], assistant_steps, resolved_call_ids)
    usage = normalize_usage(body["usage"], assistant_steps, model)
    provider_meta = build_provider_meta(body, builtin_tools)

    metadata =
      %{
        response_id: body["id"],
        response_model: body["model"] || body["agent"] || model.id,
        finish_reason: finish_reason,
        finish_reason_raw: body["status"],
        provider_meta: provider_meta,
        google_interactions_steps: assistant_steps
      }
      |> Helpers.maybe_put_usage_meta(usage)

    with {:ok, response} <-
           ResponseBuilder.build_response(chunks, metadata, context: context, model: model) do
      response =
        response
        |> maybe_unwrap_interaction_object(opts, body)
        |> maybe_attach_interaction_error(body)

      {:ok, response}
    end
  end

  def interactions_usage_body?(%{"usage" => usage} = body)
      when is_map(usage) and map_size(usage) > 0 do
    body["object"] == "interaction" or
      Enum.any?(@interactions_usage_keys, &Map.has_key?(usage, &1))
  end

  def interactions_usage_body?(_body), do: false

  def extract_usage(%{"usage" => usage_map} = body, model)
      when is_map(usage_map) and map_size(usage_map) > 0 do
    if interactions_usage_body?(body) do
      assistant_steps =
        body
        |> Map.get("steps", [])
        |> List.wrap()
        |> StepHistory.slice_latest_turn_steps()
        |> Enum.reject(&(Map.get(&1, "type") in ["user_input", "function_result"]))

      {:ok, normalize_usage(usage_map, assistant_steps, model)}
    else
      {:error, :no_usage_found}
    end
  end

  def extract_usage(%ReqLLM.Response{usage: usage}, _model) when is_map(usage), do: {:ok, usage}
  def extract_usage(_, _), do: {:error, :no_usage_found}

  def decode_steps_to_chunks(steps, interaction_id) do
    {turn_steps, resolved_call_ids} = StepHistory.slice_latest_turn_with_resolved(steps)

    {rev_chunks, rev_assistant_steps, rev_builtins} =
      Enum.reduce(turn_steps, {[], [], []}, fn {step, idx},
                                               {chunks_acc, steps_acc, builtins_acc} ->
        normalized_step = normalize_decoded_step(step, idx, interaction_id)

        case decode_single_step(normalized_step, idx, interaction_id) do
          :skip ->
            {chunks_acc, steps_acc, builtins_acc}

          {step_chunks, builtin_entry, _step_is_fc?} ->
            new_builtins =
              if(builtin_entry, do: [builtin_entry | builtins_acc], else: builtins_acc)

            step_chunks =
              if MapSet.member?(resolved_call_ids, normalized_step["id"]) and
                   normalized_step["type"] == "function_call",
                 do: [],
                 else: step_chunks

            {Enum.reverse(step_chunks, chunks_acc), [normalized_step | steps_acc], new_builtins}
        end
      end)

    {Enum.reverse(rev_chunks), Enum.reverse(rev_assistant_steps), Enum.reverse(rev_builtins),
     resolved_call_ids}
  end

  def normalize_decoded_step(%{"type" => "function_call"} = step, idx, interaction_id) do
    case step["id"] do
      id when is_binary(id) ->
        if Helpers.non_empty_binary?(id),
          do: step,
          else: Map.put(step, "id", fallback_call_id(interaction_id, idx))

      _ ->
        Map.put(step, "id", fallback_call_id(interaction_id, idx))
    end
  end

  def normalize_decoded_step(step, _idx, _interaction_id), do: step

  def decode_single_step(step, idx, interaction_id \\ nil)

  def decode_single_step(%{"type" => type}, _idx, _interaction_id)
      when type in ["user_input", "function_result"],
      do: :skip

  def decode_single_step(%{"type" => "thought"} = step, idx, _interaction_id) do
    text =
      step
      |> Map.get("summary", [])
      |> List.wrap()
      |> Enum.map_join("", fn
        %{"type" => "text", "text" => t} when is_binary(t) -> t
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end)

    sig = step["signature"]

    if text == "" and not Helpers.non_empty_binary?(sig) do
      :skip
    else
      meta =
        %{
          format: "google-interactions-v1",
          provider_data: %{"type" => "thought"},
          step_index: idx
        }
        |> Helpers.maybe_put_atom_key(:signature, sig)

      {[StreamChunk.thinking(text, meta)], nil, false}
    end
  end

  def decode_single_step(%{"type" => "model_output"} = step, _idx, _interaction_id) do
    chunks =
      step
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.flat_map(&decode_model_output_content_item/1)

    {chunks, nil, false}
  end

  def decode_single_step(%{"type" => "function_call"} = step, idx, interaction_id) do
    case step["name"] do
      name when is_binary(name) and name != "" ->
        args = step["arguments"] || %{}
        raw_id = step["id"]

        call_id =
          if Helpers.non_empty_binary?(raw_id),
            do: raw_id,
            else: fallback_call_id(interaction_id, idx)

        meta =
          %{id: call_id, index: idx}
          |> Helpers.maybe_put_atom_key(:signature, step["signature"])

        chunk = StreamChunk.tool_call(name, args, meta)
        {[chunk], nil, true}

      _ ->
        :skip
    end
  end

  def decode_single_step(%{"type" => step_type} = step, _idx, _interaction_id)
      when is_binary(step_type) do
    block = ContentPart.provider_block(:google, step, %{api: :interactions})
    {[StreamChunk.content_part(block)], summarize_builtin_step(step), false}
  end

  def decode_single_step(_step, _idx, _interaction_id), do: :skip

  def fallback_call_id(interaction_id, idx)
      when is_binary(interaction_id) and interaction_id != "" do
    "call_#{interaction_id}_#{idx}"
  end

  def fallback_call_id(_interaction_id, idx), do: "call_#{idx}"

  def decode_model_output_content_item(%{"type" => "text", "text" => text} = item)
      when is_binary(text) do
    case item["annotations"] do
      anns when is_list(anns) and anns != [] ->
        if text != "" do
          [StreamChunk.content_part(ContentPart.text(text, %{annotations: anns}))]
        else
          [StreamChunk.meta(%{annotations: anns})]
        end

      _ ->
        if(text != "", do: [StreamChunk.text(text)], else: [])
    end
  end

  def decode_model_output_content_item(%{"type" => "image"} = item) do
    [StreamChunk.content_part(decode_media_content_part(:image, item, "image/png"))]
  end

  def decode_model_output_content_item(%{"type" => type} = item)
      when type in ["audio", "video", "document"] do
    [StreamChunk.content_part(decode_media_content_part({:file, type}, item, nil))]
  end

  def decode_model_output_content_item(%{} = item) do
    [
      StreamChunk.content_part(
        ContentPart.provider_block(:google, item, %{api: :interactions, content_item: true})
      )
    ]
  end

  def decode_model_output_content_item(_item), do: []

  def decode_media_content_part(:image, %{"data" => data} = item, default_mime)
      when is_binary(data) do
    mime = item["mime_type"] || default_mime

    case decode_base64_media(data) do
      {:ok, raw} ->
        ContentPart.image(raw, mime)

      :error ->
        ContentPart.provider_block(:google, item, %{api: :interactions, content_item: true})
    end
  end

  def decode_media_content_part(:image, %{"uri" => uri} = item, _default_mime)
      when is_binary(uri) do
    meta = if(item["mime_type"], do: %{mime_type: item["mime_type"]}, else: %{})
    ContentPart.image_url(uri, meta)
  end

  def decode_media_content_part({:file, block_type}, %{"data" => data} = item, _default_mime)
      when is_binary(data) do
    mime = item["mime_type"] || default_mime_for_block_type(block_type)
    meta = %{interactions_type: block_type}

    case decode_base64_media(data) do
      {:ok, raw} ->
        ContentPart.file(raw, "attachment", mime, meta)

      :error ->
        ContentPart.provider_block(:google, item, %{api: :interactions, content_item: true})
    end
  end

  def decode_media_content_part({:file, block_type}, %{"uri" => uri} = item, _default_mime)
      when is_binary(uri) do
    meta = %{interactions_type: block_type}
    %ContentPart{type: :file, file_id: uri, media_type: item["mime_type"], metadata: meta}
  end

  def decode_media_content_part(_kind, item, _default_mime) do
    ContentPart.provider_block(:google, item, %{api: :interactions, content_item: true})
  end

  defp decode_base64_media(data) when is_binary(data) do
    cleaned = String.replace(data, ~r/\s+/, "")

    case Base.decode64(cleaned, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> Base.url_decode64(cleaned, padding: false)
    end
  end

  defp default_mime_for_block_type("audio"), do: "audio/mpeg"
  defp default_mime_for_block_type("video"), do: "video/mp4"
  defp default_mime_for_block_type("document"), do: "application/pdf"
  defp default_mime_for_block_type(_), do: "application/octet-stream"

  def resolve_finish_reason(status, assistant_steps, resolved_call_ids \\ MapSet.new()) do
    has_fc? =
      Enum.any?(assistant_steps, fn step ->
        Map.get(step, "type") == "function_call" and
          not MapSet.member?(resolved_call_ids, Map.get(step, "id"))
      end)

    cond do
      status == "requires_action" or (status == "completed" and has_fc?) -> :tool_calls
      is_nil(status) -> nil
      Map.has_key?(@status_finish_reasons, status) -> Map.fetch!(@status_finish_reasons, status)
      true -> :unknown
    end
  end

  def normalize_usage(usage, steps, model) when not is_map(usage) or map_size(usage) == 0 do
    tool_usage = interactions_tool_usage(steps, model)

    if map_size(tool_usage) > 0 do
      %{tool_usage: tool_usage}
    else
      nil
    end
  end

  def normalize_usage(usage, steps, model) when is_map(usage) do
    input = usage["total_input_tokens"] || 0
    reasoning = usage["total_thought_tokens"] || 0
    raw_output = usage["total_output_tokens"] || 0
    output = raw_output + reasoning
    cached = usage["total_cached_tokens"] || 0
    tool_use_input = usage["total_tool_use_tokens"] || 0
    total = usage["total_tokens"] || input + output + tool_use_input

    base = %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cached_tokens: cached,
      reasoning_tokens: reasoning,
      tool_use_input_tokens: tool_use_input
    }

    step_tool_usage = interactions_tool_usage(steps, model)
    grounding_tool_usage = normalize_grounding_tool_count(usage["grounding_tool_count"], model)
    tool_usage = Map.merge(step_tool_usage, grounding_tool_usage)

    if map_size(tool_usage) > 0 do
      Map.put(base, :tool_usage, tool_usage)
    else
      base
    end
  end

  def attach_step_tool_usage(nil, steps, model) do
    case interactions_tool_usage(steps, model) do
      tool_usage when map_size(tool_usage) > 0 -> %{tool_usage: tool_usage}
      _ -> nil
    end
  end

  def attach_step_tool_usage(usage, steps, model) when is_map(usage) do
    step_tool_usage = interactions_tool_usage(steps, model)
    existing_tool_usage = Map.get(usage, :tool_usage) || %{}
    merged_tool_usage = Map.merge(step_tool_usage, existing_tool_usage)

    if map_size(merged_tool_usage) > 0 do
      Map.put(usage, :tool_usage, merged_tool_usage)
    else
      usage
    end
  end

  defp interactions_tool_usage(steps, model) when is_list(steps) do
    Enum.reduce(steps, %{}, fn step, acc ->
      accumulate_step_tool_usage(step, acc, model)
    end)
    |> resolve_search_step_usage(steps, model)
  end

  defp interactions_tool_usage(_steps, _model), do: %{}

  defp accumulate_step_tool_usage(%{"type" => type}, acc, model)
       when is_map_key(@builtin_call_tool_keys, type) do
    tool_key = Map.fetch!(@builtin_call_tool_keys, type)
    unit = resolve_tool_unit(model, tool_key)

    Map.update(acc, tool_key, %{count: 1, unit: unit}, fn existing ->
      %{existing | count: existing.count + 1}
    end)
  end

  defp accumulate_step_tool_usage(_step, acc, _model), do: acc

  defp resolve_search_step_usage(acc, steps, model) do
    search_steps = Enum.filter(steps, &(Map.get(&1, "type") == "google_search_call"))

    if search_steps == [] do
      acc
    else
      configured_unit = resolve_tool_unit(model, :web_search)
      query_lists = Enum.map(search_steps, &extract_search_queries/1)

      {count, unit} =
        if configured_unit == :query and Enum.any?(query_lists, &(&1 != [])) do
          total_queries =
            Enum.reduce(query_lists, 0, fn
              [], total -> total + 1
              queries, total -> total + length(queries)
            end)

          {total_queries, :query}
        else
          {length(search_steps), :call}
        end

      Map.merge(acc, ToolUsage.build(:web_search, count, unit))
    end
  end

  defp extract_search_queries(%{"arguments" => %{"queries" => list}}) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end

  defp extract_search_queries(_step), do: []

  defp normalize_grounding_tool_count(counts, model) when is_list(counts) do
    Enum.reduce(counts, %{}, fn
      %{"tool" => raw_tool, "count" => count}, acc
      when is_binary(raw_tool) and is_number(count) and count > 0 ->
        tool_key = Map.get(@grounding_tool_keys, raw_tool, raw_tool)
        unit = resolve_tool_unit(model, tool_key)

        Map.update(acc, tool_key, %{count: count, unit: unit}, fn existing ->
          %{existing | count: existing.count + count}
        end)

      _, acc ->
        acc
    end)
  end

  defp normalize_grounding_tool_count(_, _model), do: %{}

  defp resolve_tool_unit(model, tool_key) do
    raw_unit = if(model, do: ReqLLM.Pricing.tool_unit(model, tool_key), else: nil)

    case raw_unit do
      "query" -> :query
      "call" -> :call
      nil -> :call
      other -> other
    end
  end

  def build_provider_meta(body, builtin_tools) do
    %{}
    |> Helpers.maybe_put_string("interaction_id", body["id"])
    |> Helpers.maybe_put_string("interaction_status", body["status"])
    |> Helpers.maybe_put_string("agent", body["agent"])
    |> Helpers.maybe_put_string("service_tier", body["service_tier"])
    |> Helpers.maybe_put_string("environment_id", body["environment_id"])
    |> Helpers.maybe_put_string("continuation_token", body["continuation_token"])
    |> Helpers.maybe_put_non_empty_list("errors", body["errors"])
    |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)
    |> Helpers.maybe_put_non_empty_map("google_usage", Helpers.stringify_if_map(body["usage"]))
  end

  def summarize_builtin_step(step) do
    Map.take(step, ["type", "id", "call_id", "arguments", "result", "is_error"])
  end

  def extract_builtin_tools(steps) when is_list(steps) do
    steps
    |> Enum.filter(fn step ->
      type = Map.get(step, "type")

      is_binary(type) and
        type not in ["user_input", "function_result", "thought", "model_output", "function_call"]
    end)
    |> Enum.map(&summarize_builtin_step/1)
  end

  defp maybe_unwrap_interaction_object(
         %ReqLLM.Response{message: %{tool_calls: [_ | _]}} = response,
         _opts,
         _body
       ),
       do: response

  defp maybe_unwrap_interaction_object(%ReqLLM.Response{} = response, opts, body) do
    status = body["status"]

    should_unwrap? =
      status in [nil, "completed"] and
        (Keyword.get(opts, :operation) == :object or
           Helpers.json_response_format?(Helpers.get_opt(opts, :response_format)) or
           Helpers.json_response_format?(body["response_format"]))

    if should_unwrap? do
      case ReqLLM.Response.unwrap_object(response, opts) do
        {:ok, object} -> %{response | object: object}
        {:error, _} -> response
      end
    else
      response
    end
  end

  defp maybe_attach_interaction_error(
         %ReqLLM.Response{} = response,
         %{"status" => "failed"} = body
       ) do
    %{
      response
      | error: ResponseError.exception(reason: extract_failure_reason(body), response_body: body)
    }
  end

  defp maybe_attach_interaction_error(%ReqLLM.Response{} = response, _body), do: response

  def extract_failure_reason(%{"errors" => [%{"message" => message} | _]}), do: message
  def extract_failure_reason(%{"error" => %{"message" => message}}), do: message
  def extract_failure_reason(_), do: "Google Interaction failed"

  def extract_http_error_reason(%{"error" => %{"message" => message}}, _fallback), do: message

  def extract_http_error_reason(%{"errors" => [%{"message" => message} | _]}, _fallback),
    do: message

  def extract_http_error_reason(_, fallback), do: fallback
end
