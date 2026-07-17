defmodule ReqLLM.OpenAI.Realtime.EventProjector do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.OpenAI.Realtime.Event
  alias ReqLLM.Response.Projection
  alias ReqLLM.StreamEvent

  @redacted "[REDACTED]"
  @payload_keys MapSet.new(
                  ~w(arguments audio content delta input instructions message output text transcript)
                )
  @secret_keys MapSet.new(~w(
    access_token api_key api_token authorization client_secret cookie credential credentials header headers
    password secret signature token
  ))
  @correlation_keys [
    {"call_id", :call_id},
    {"content_index", :content_index},
    {"conversation_id", :conversation_id},
    {"event_id", :event_id},
    {"item_id", :item_id},
    {"output_index", :output_index},
    {"previous_item_id", :previous_item_id},
    {"response_id", :response_id},
    {"sequence_number", :sequence_number},
    {"session_id", :session_id}
  ]

  @spec project(map(), keyword()) :: Event.t()
  def project(event, opts) when is_map(event) and is_list(opts) do
    payloads = Keyword.fetch!(opts, :payloads)

    %Event{
      type: value(event, "type"),
      native: native_event(event, payloads),
      stream_events: stream_events(event, opts)
    }
  end

  defp stream_events(event, opts) do
    case value(event, "type") do
      "response.created" -> response_started(event, opts)
      "response.output_text.delta" -> text_delta(event, opts, :text)
      "response.output_audio_transcript.delta" -> text_delta(event, opts, :audio_transcript)
      "response.output_item.added" -> tool_call_started(event)
      "response.function_call_arguments.delta" -> tool_call_delta(event, opts)
      "response.function_call_arguments.done" -> tool_call_done(event, opts)
      "conversation.item.done" -> tool_result(event, opts)
      "response.done" -> response_done(event, opts)
      _type -> []
    end
  end

  defp response_started(event, opts) do
    case Keyword.get(opts, :model) do
      %LLMDB.Model{} = model ->
        data = %{
          model: %{id: model.provider_model_id || model.id || model.model, provider: :openai}
        }

        [StreamEvent.new(:start, data, correlation(event))]

      _model ->
        []
    end
  end

  defp text_delta(event, opts, modality) do
    case value(event, "delta") do
      delta when is_binary(delta) ->
        metadata = Map.put(correlation(event), :modality, modality)
        [StreamEvent.new(:text_delta, payload(delta, opts), metadata)]

      _delta ->
        []
    end
  end

  defp tool_call_started(event) do
    item = map_value(event, "item")

    with "function_call" <- value(item, "type"),
         id when is_binary(id) and id != "" <- value(item, "call_id") || value(item, "id"),
         name when is_binary(name) and name != "" <- value(item, "name") do
      data = %{
        id: id,
        index: non_negative_index(event),
        name: name,
        arguments: %{}
      }

      [StreamEvent.new(:tool_call_start, data, correlation(event, item))]
    else
      _item -> []
    end
  end

  defp tool_call_delta(event, opts) do
    with id when is_binary(id) and id != "" <- event_call_id(event),
         delta when is_binary(delta) <- value(event, "delta") do
      data = %{
        id: id,
        index: non_negative_index(event),
        fragment: payload(delta, opts)
      }

      [StreamEvent.new(:tool_call_delta, data, correlation(event))]
    else
      _event -> []
    end
  end

  defp tool_call_done(event, opts) do
    with id when is_binary(id) and id != "" <- event_call_id(event),
         name when is_binary(name) and name != "" <- value(event, "name"),
         arguments when is_binary(arguments) <- value(event, "arguments"),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(arguments) do
      data = %{
        id: id,
        name: name,
        arguments: if(raw_payloads?(opts), do: decoded, else: %{"redacted" => true})
      }

      [StreamEvent.new(:tool_call, data, correlation(event))]
    else
      _event -> []
    end
  end

  defp tool_result(event, opts) do
    item = map_value(event, "item")

    with "function_call_output" <- value(item, "type"),
         id when is_binary(id) and id != "" <- value(item, "call_id"),
         output when is_binary(output) <- value(item, "output") do
      result = Context.tool_result(id, payload(output, opts))
      [StreamEvent.new(:tool_result, result, correlation(event, item))]
    else
      _item -> []
    end
  end

  defp response_done(event, opts) do
    response = map_value(event, "response")
    usage_events = usage_events(event, response)

    case value(response, "status") do
      "completed" ->
        finish_reason = if function_call_output?(response), do: :tool_calls, else: :stop
        usage_events ++ [terminal_event(:finish, finish_reason, event, response)]

      "cancelled" ->
        usage_events ++ [terminal_event(:cancelled, :cancelled, event, response)]

      "failed" ->
        error = response_error(response, opts)
        usage_events ++ [StreamEvent.new(:error, error, terminal_metadata(event, response))]

      "incomplete" ->
        finish_reason = incomplete_finish_reason(response)
        usage_events ++ [terminal_event(:finish, finish_reason, event, response)]

      _status ->
        []
    end
  end

  defp usage_events(event, response) do
    case map_value(response, "usage") do
      usage when map_size(usage) > 0 ->
        normalized =
          usage
          |> copy_realtime_cached_tokens()
          |> ReqLLM.Usage.normalize()

        [StreamEvent.new(:usage, normalized, correlation(event, response))]

      _usage ->
        []
    end
  end

  defp terminal_event(type, finish_reason, event, response) do
    StreamEvent.new(type, %{finish_reason: finish_reason}, terminal_metadata(event, response))
  end

  defp terminal_metadata(event, response) do
    event
    |> correlation(response)
    |> put_available(:status, value(response, "status"))
    |> put_available(:status_reason, status_reason(response))
  end

  defp response_error(response, opts) do
    error = response |> map_value("status_details") |> map_value("error")

    cond do
      map_size(error) == 0 -> %{type: "realtime_response_failed"}
      raw_payloads?(opts) -> error
      true -> sanitize_native(error)
    end
  end

  defp incomplete_finish_reason(response) do
    case status_reason(response) do
      "max_output_tokens" -> :length
      "content_filter" -> :content_filter
      _reason -> :incomplete
    end
  end

  defp status_reason(response) do
    response
    |> map_value("status_details")
    |> value("reason")
  end

  defp function_call_output?(response) do
    response
    |> list_value("output")
    |> Enum.any?(&(value(&1, "type") == "function_call"))
  end

  defp copy_realtime_cached_tokens(usage) do
    case usage |> map_value("input_token_details") |> value("cached_tokens") do
      cached when is_number(cached) -> Map.put(usage, "cached_tokens", cached)
      _cached -> usage
    end
  end

  defp native_event(event, :raw), do: event
  defp native_event(event, :none), do: sanitize_native(event)

  defp sanitize_native(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, sanitize_native_value(key, nested)} end)
  end

  defp sanitize_native(value) when is_list(value), do: Enum.map(value, &sanitize_native/1)
  defp sanitize_native(value), do: value

  defp sanitize_native_value(key, value) when is_map(value) do
    if sensitive_key?(key),
      do: @redacted,
      else: sanitize_native(value)
  end

  defp sanitize_native_value(key, value) when is_list(value) do
    if sensitive_key?(key) do
      @redacted
    else
      Enum.map(value, &sanitize_native/1)
    end
  end

  defp sanitize_native_value(key, value) when is_binary(value) do
    if sensitive_key?(key) do
      @redacted
    else
      safe_leaf(key, value)
    end
  end

  defp sanitize_native_value(key, value) do
    if sensitive_key?(key),
      do: @redacted,
      else: safe_leaf(key, value)
  end

  defp safe_leaf(key, value) do
    %{key => value}
    |> Projection.safe_metadata()
    |> Map.fetch!(key)
  end

  defp correlation(event, nested \\ %{}) do
    @correlation_keys
    |> Enum.reduce(%{provider_event_type: value(event, "type")}, fn {key, field}, metadata ->
      put_available(metadata, field, value(event, key) || value(nested, key))
    end)
    |> put_available(:item_id, item_id(event, nested))
    |> put_available(:response_id, response_id(event, nested))
  end

  defp item_id(event, nested) do
    value(event, "item_id") || value(nested, "item_id") || value(nested, "id")
  end

  defp response_id(event, nested) do
    value(event, "response_id") || value(nested, "response_id") ||
      event |> map_value("response") |> value("id")
  end

  defp event_call_id(event), do: value(event, "call_id") || value(event, "item_id")

  defp non_negative_index(event) do
    case value(event, "output_index") do
      index when is_integer(index) and index >= 0 -> index
      _index -> 0
    end
  end

  defp payload(value, opts), do: if(raw_payloads?(opts), do: value, else: @redacted)
  defp raw_payloads?(opts), do: Keyword.fetch!(opts, :payloads) == :raw

  defp put_available(map, _key, nil), do: map
  defp put_available(map, key, value), do: Map.put(map, key, value)

  defp map_value(map, key) do
    case value(map, key) do
      nested when is_map(nested) -> nested
      _nested -> %{}
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      nested when is_list(nested) -> nested
      _nested -> []
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp value(_map, _key), do: nil

  defp normalized_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalized_key(key) when is_binary(key), do: key
  defp normalized_key(key), do: to_string(key)

  defp sensitive_key?(key) do
    normalized = normalized_key(key)
    MapSet.member?(@payload_keys, normalized) or MapSet.member?(@secret_keys, normalized)
  end
end
