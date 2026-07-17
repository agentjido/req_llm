defmodule ReqLLM.Response.Projection do
  @moduledoc false

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.Response.OutputItem

  @redacted "[REDACTED]"

  @sensitive_metadata_keys MapSet.new(~w(
    access_token api_key api_token audio authorization body bytes code_interpreter content contents cookie
    credential credentials data encrypted encrypted_content encrypted_reasoning error file file_data file_id files header
    headers image images input inputs instructions logprobs messages password prompt prompts reasoning
    output outputs provider_item provider_items raw_request raw_response reasoning_details request request_body
    response response_body secret signature thinking token video web_search_queries
  ))

  @source_keys [
    :source,
    "source",
    :sources,
    "sources",
    :citation,
    "citation",
    :citations,
    "citations"
  ]
  @annotation_keys [:annotation, "annotation", :annotations, "annotations"]
  @refusal_keys [:refusal, "refusal", :refusals, "refusals"]
  @provider_item_keys [:provider_item, "provider_item", :provider_items, "provider_items"]

  @spec output_items(Response.t()) :: [OutputItem.t()]
  def output_items(%Response{} = response) do
    message_items(response.message) ++ provider_output_items(response.provider_meta)
  end

  @spec call_metadata(Response.t()) :: map()
  def call_metadata(%Response{} = response) do
    metadata_sources = message_metadata(response.message) ++ [response.provider_meta]

    %{response_id: response.id, model: response.model}
    |> put_available(:finish_reason, response.finish_reason)
    |> put_available(:usage, response.usage)
    |> put_available(:request_id, request_id(metadata_sources))
    |> put_available(:raw_finish_reason, raw_finish_reason(metadata_sources))
    |> put_available(:warnings, warnings(metadata_sources))
    |> put_available(:attempts, attempts(metadata_sources))
    |> put_available(:timings, timings(metadata_sources))
    |> put_available(:provider_metadata, safe_provider_metadata(response.provider_meta))
  end

  defp message_items(nil), do: []

  defp message_items(%Message{} = message) do
    content_items = Enum.flat_map(message.content || [], &content_output_items/1)
    reasoning_items = reasoning_detail_items(message.reasoning_details, content_items)
    tool_items = Enum.map(message.tool_calls || [], &output_item(:tool_call, &1))
    content_items ++ reasoning_items ++ tool_items
  end

  defp content_output_items(%ContentPart{} = part) do
    [content_part_item(part)] ++ metadata_output_items(part.metadata)
  end

  defp content_output_items(_value), do: []

  defp content_part_item(%ContentPart{type: type, text: text, metadata: metadata})
       when type in [:text, :thinking] do
    output_item(type, text || "", safe_metadata(metadata))
  end

  defp content_part_item(%ContentPart{type: type, metadata: metadata} = part)
       when type in [:image, :image_url, :video_url, :file] do
    output_item(type, part, safe_metadata(metadata))
  end

  defp content_part_item(%ContentPart{metadata: metadata} = part) do
    output_item(:provider_item, part, safe_metadata(metadata))
  end

  defp reasoning_detail_items(details, content_items) when is_list(details) do
    existing_texts =
      content_items
      |> Enum.flat_map(fn
        %OutputItem{type: :thinking, data: text} when is_binary(text) -> [text]
        _item -> []
      end)
      |> MapSet.new()

    {items, _seen_texts} =
      Enum.reduce(details, {[], existing_texts}, fn detail, {items, seen_texts} ->
        case reasoning_detail_value(detail) do
          {text, metadata} when is_binary(text) and text != "" ->
            if MapSet.member?(seen_texts, text) do
              {items, seen_texts}
            else
              {[output_item(:thinking, text, metadata) | items], MapSet.put(seen_texts, text)}
            end

          _unavailable ->
            {items, seen_texts}
        end
      end)

    Enum.reverse(items)
  end

  defp reasoning_detail_items(_details, _content_items), do: []

  defp reasoning_detail_value(%Message.ReasoningDetails{} = detail) do
    metadata = detail |> Map.from_struct() |> Map.delete(:text) |> safe_metadata()
    {detail.text, metadata}
  end

  defp reasoning_detail_value(detail) when is_map(detail) do
    text = Map.get(detail, :text) || Map.get(detail, "text")
    metadata = detail |> Map.delete(:text) |> Map.delete("text") |> safe_metadata()
    {text, metadata}
  end

  defp reasoning_detail_value(_detail), do: nil

  defp metadata_output_items(metadata) when is_map(metadata) do
    values_for_keys(metadata, @source_keys)
    |> output_items_for(:source)
    |> Kernel.++(values_for_keys(metadata, @annotation_keys) |> output_items_for(:annotation))
    |> Kernel.++(values_for_keys(metadata, @refusal_keys) |> output_items_for(:refusal))
    |> Kernel.++(
      values_for_keys(metadata, @provider_item_keys)
      |> output_items_for(:provider_item)
    )
  end

  defp metadata_output_items(_metadata), do: []

  defp provider_output_items(provider_meta) when is_map(provider_meta) do
    source_items =
      values_for_keys(provider_meta, @source_keys) ++
        (provider_meta
         |> nested_map(:google)
         |> values_for_keys(@source_keys))

    annotation_items = values_for_keys(provider_meta, @annotation_keys)
    refusal_items = values_for_keys(provider_meta, @refusal_keys)

    provider_items =
      values_for_keys(provider_meta, @provider_item_keys) ++
        (provider_meta
         |> nested_map(:code_interpreter)
         |> values_for_keys([:items, "items"]))

    output_items_for(source_items, :source) ++
      output_items_for(annotation_items, :annotation) ++
      output_items_for(refusal_items, :refusal) ++
      output_items_for(provider_items, :provider_item)
  end

  defp provider_output_items(_provider_meta), do: []

  defp output_items_for(values, type) do
    Enum.map(values, &output_item(type, sanitize_urls(&1)))
  end

  defp output_item(type, data, metadata \\ %{}) do
    %OutputItem{type: type, data: data, metadata: metadata}
  end

  defp values_for_keys(map, keys) when is_map(map) do
    keys
    |> Enum.flat_map(fn key -> normalize_values(Map.get(map, key)) end)
    |> Enum.uniq()
  end

  defp normalize_values(nil), do: []
  defp normalize_values(values) when is_list(values), do: Enum.reject(values, &is_nil/1)
  defp normalize_values(value), do: [value]

  defp nested_map(map, name) do
    case Map.get(map, name) || Map.get(map, Atom.to_string(name)) do
      nested when is_map(nested) -> nested
      _other -> %{}
    end
  end

  defp message_metadata(%Message{metadata: metadata}) when is_map(metadata), do: [metadata]
  defp message_metadata(_message), do: []

  defp request_id(sources) do
    case first_available(sources, [:request_id, "request_id"]) || nested_id(sources, :request) do
      id when is_binary(id) and id != "" -> id
      _other -> nil
    end
  end

  defp raw_finish_reason(sources) do
    case first_available(sources, [
           :raw_finish_reason,
           "raw_finish_reason",
           :raw_stop_reason,
           "raw_stop_reason",
           :stop_reason,
           "stop_reason"
         ]) do
      reason when is_binary(reason) or is_atom(reason) -> reason
      _other -> nil
    end
  end

  defp warnings(sources) do
    case first_available(sources, [:warnings, "warnings"]) do
      warning when is_binary(warning) and warning != "" ->
        redact_warnings([warning], sources)

      warnings when is_list(warnings) ->
        warnings
        |> Enum.filter(&is_binary/1)
        |> redact_warnings(sources)

      _other ->
        nil
    end
  end

  defp attempts(sources) do
    case first_available(sources, [:attempts, "attempts", :attempt_count, "attempt_count"]) do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      attempts when is_list(attempts) -> length(attempts)
      _other -> nil
    end
  end

  defp timings(sources) do
    case first_available(sources, [:timings, "timings", :timing, "timing"]) do
      timings when is_map(timings) -> numeric_metadata(timings)
      _other -> nil
    end
  end

  defp nested_id(sources, name) do
    Enum.find_value(sources, fn source ->
      source
      |> nested_map(name)
      |> first_available([:id, "id"])
    end)
  end

  defp first_available(sources, keys) when is_list(sources) do
    Enum.find_value(sources, &first_available(&1, keys))
  end

  defp first_available(source, keys) when is_map(source) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(source, key) do
        {:ok, value} when value not in [nil, "", [], %{}] -> value
        _other -> nil
      end
    end)
  end

  defp first_available(_source, _keys), do: nil

  defp safe_provider_metadata(provider_meta) when is_map(provider_meta) do
    case safe_metadata(provider_meta) do
      metadata when map_size(metadata) > 0 -> metadata
      _empty -> nil
    end
  end

  defp safe_provider_metadata(_provider_meta), do: nil

  defp safe_metadata(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if redacted_metadata_key?(key) do
        {key, @redacted}
      else
        {key, safe_metadata(item)}
      end
    end)
  end

  defp safe_metadata(value) when is_list(value), do: Enum.map(value, &safe_metadata/1)

  defp safe_metadata(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&safe_metadata/1) |> List.to_tuple()

  defp safe_metadata(value) when is_binary(value), do: sanitize_url(value)
  defp safe_metadata(value), do: value

  defp sanitize_urls(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, sanitize_urls(item)} end)
  end

  defp sanitize_urls(value) when is_list(value), do: Enum.map(value, &sanitize_urls/1)
  defp sanitize_urls(value) when is_binary(value), do: sanitize_url(value)
  defp sanitize_urls(value), do: value

  defp sensitive_metadata_key?(key) when is_atom(key) or is_binary(key) do
    name = key |> to_string() |> Macro.underscore() |> String.downcase()

    MapSet.member?(@sensitive_metadata_keys, name) or
      String.ends_with?(name, ["_key", "_token", "_secret", "_password", "_header", "_headers"]) or
      String.ends_with?(name, "_body") or
      String.contains?(name, "credential") or
      String.starts_with?(name, "auth_") or
      String.ends_with?(name, "_auth")
  end

  defp sensitive_metadata_key?(_key), do: false

  defp redacted_metadata_key?(key) when is_atom(key) or is_binary(key) do
    sensitive_metadata_key?(key) or
      (key |> to_string() |> Macro.underscore() |> String.downcase()) in ["warning", "warnings"]
  end

  defp redacted_metadata_key?(_key), do: false

  defp numeric_metadata(map) do
    map
    |> Enum.flat_map(fn
      {key, value} when is_number(value) -> [{key, value}]
      {key, value} when is_map(value) -> nested_numeric_metadata(key, value)
      _other -> []
    end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      values -> values
    end
  end

  defp nested_numeric_metadata(key, value) do
    case numeric_metadata(value) do
      nil -> []
      nested -> [{key, nested}]
    end
  end

  defp sanitize_url(value) do
    if String.starts_with?(value, ["https://", "http://"]) do
      ReqLLM.Provider.Utils.sanitize_url(value)
    else
      value
    end
  rescue
    _error -> value
  end

  defp redact_warnings(warnings, sources) do
    values = Enum.flat_map(sources, &sensitive_values/1)

    Enum.map(warnings, fn warning ->
      Enum.reduce(values, warning, fn value, redacted ->
        String.replace(redacted, value, @redacted)
      end)
    end)
  end

  defp sensitive_values(value) when is_map(value) do
    Enum.flat_map(value, fn {key, item} ->
      if sensitive_metadata_key?(key) do
        binary_values(item)
      else
        sensitive_values(item)
      end
    end)
  end

  defp sensitive_values(value) when is_list(value), do: Enum.flat_map(value, &sensitive_values/1)
  defp sensitive_values(_value), do: []

  defp binary_values(value) when is_binary(value), do: if(value == "", do: [], else: [value])

  defp binary_values(value) when is_map(value),
    do: Enum.flat_map(value, fn {_key, item} -> binary_values(item) end)

  defp binary_values(value) when is_list(value), do: Enum.flat_map(value, &binary_values/1)
  defp binary_values(_value), do: []

  defp put_available(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp put_available(map, key, value), do: Map.put(map, key, value)
end
