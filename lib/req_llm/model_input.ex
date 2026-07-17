defmodule ReqLLM.ModelInput do
  @moduledoc false

  @ambiguous_keys %{
    chat: [:stream, :stream_transport, :defer_http_events_until_telemetry?, :on_finch_request],
    object: [:stream, :stream_transport, :defer_http_events_until_telemetry?, :on_finch_request],
    rerank: [:query, :documents]
  }

  @spec merge_tuple_defaults(ReqLLM.model_input(), atom(), keyword()) :: keyword()
  def merge_tuple_defaults(model_input, operation, call_opts) do
    {merged, warnings} = merge_tuple_defaults_with_warnings(model_input, operation, call_opts)
    Enum.each(warnings, &IO.warn/1)
    merged
  end

  @doc false
  @spec merge_tuple_defaults_with_warnings(ReqLLM.model_input(), atom(), keyword()) ::
          {keyword(), [binary()]}
  def merge_tuple_defaults_with_warnings(
        {provider, model_id, tuple_opts},
        operation,
        call_opts
      )
      when is_atom(provider) and is_binary(model_id) and is_list(call_opts) do
    if Keyword.keyword?(tuple_opts) do
      {defaults, ignored} = select_defaults(tuple_opts, operation)
      warnings = ignored_defaults_warnings(operation, ignored, tuple_opts, call_opts)
      {merge_defaults(defaults, call_opts), warnings}
    else
      {call_opts, invalid_container_warnings(operation, call_opts)}
    end
  end

  def merge_tuple_defaults_with_warnings(_model_input, _operation, call_opts),
    do: {call_opts, []}

  defp select_defaults(tuple_opts, operation) do
    schema = option_schema(operation).schema
    ambiguous_keys = Map.get(@ambiguous_keys, operation, [])

    tuple_opts
    |> Enum.reduce({[], [], MapSet.new()}, fn {key, value}, {defaults, ignored, seen} ->
      cond do
        MapSet.member?(seen, key) ->
          {defaults, [{key, :duplicate} | ignored], seen}

        key in ambiguous_keys ->
          {defaults, [{key, :ambiguous} | ignored], MapSet.put(seen, key)}

        not Keyword.has_key?(schema, key) ->
          {defaults, [{key, :unsupported} | ignored], MapSet.put(seen, key)}

        valid_option?(key, value, schema) ->
          {[{key, value} | defaults], ignored, MapSet.put(seen, key)}

        true ->
          {defaults, [{key, :invalid} | ignored], MapSet.put(seen, key)}
      end
    end)
    |> then(fn {defaults, ignored, _seen} ->
      {Enum.reverse(defaults), Enum.reverse(ignored)}
    end)
  end

  defp valid_option?(key, value, schema) do
    option_schema = NimbleOptions.new!([{key, Keyword.fetch!(schema, key)}])
    match?({:ok, _validated}, NimbleOptions.validate([{key, value}], option_schema))
  end

  defp option_schema(:chat), do: ReqLLM.Generation.schema()
  defp option_schema(:object), do: ReqLLM.Generation.schema()
  defp option_schema(:embedding), do: ReqLLM.Embedding.schema()
  defp option_schema(:image), do: ReqLLM.Images.schema()
  defp option_schema(:transcription), do: ReqLLM.Transcription.schema()
  defp option_schema(:speech), do: ReqLLM.Speech.schema()
  defp option_schema(:rerank), do: ReqLLM.Rerank.schema()
  defp option_schema(:ocr), do: ReqLLM.OCR.schema()

  defp merge_defaults(defaults, call_opts) do
    Keyword.merge(defaults, call_opts)
  end

  defp ignored_defaults_warnings(_operation, [], _tuple_opts, _call_opts), do: []

  defp ignored_defaults_warnings(operation, ignored, tuple_opts, call_opts) do
    if warning_enabled?(tuple_opts, call_opts) do
      details = Enum.map_join(ignored, ", ", &format_ignored/1)

      [
        "Ignoring tuple model defaults for #{operation}: #{details}. " <>
          "Pass only documented #{operation} options; explicit call options take precedence."
      ]
    else
      []
    end
  end

  defp invalid_container_warnings(operation, call_opts) do
    if warning_enabled?([], call_opts) do
      [
        "Ignoring tuple model defaults for #{operation}: the third tuple element must be a keyword list."
      ]
    else
      []
    end
  end

  defp warning_enabled?(tuple_opts, call_opts) do
    policy =
      Keyword.get(call_opts, :on_unsupported, Keyword.get(tuple_opts, :on_unsupported, :warn))

    policy != :ignore
  end

  defp format_ignored({key, :duplicate}), do: "#{inspect(key)} is duplicated"

  defp format_ignored({key, :ambiguous}),
    do: "#{inspect(key)} is controlled by the operation boundary, not the model"

  defp format_ignored({key, :unsupported}),
    do: "#{inspect(key)} is not accepted by this operation"

  defp format_ignored({key, :invalid}), do: "#{inspect(key)} has an invalid value"
end
