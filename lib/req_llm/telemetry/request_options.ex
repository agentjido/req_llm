defmodule ReqLLM.Telemetry.RequestOptions do
  @moduledoc """
  Normalizes caller-facing inference options into the compact `request_options`
  map exposed on `[:req_llm, :request, *]` telemetry metadata.

  The shape is OTel-attribute-friendly — keys map 1:1 to
  `gen_ai.request.*` attributes in `ReqLLM.OpenTelemetry.Attributes` — but
  the data lives in the telemetry context and is available to any
  consumer of the lifecycle events.

  Keys whose value is `nil` are dropped so consumers never see
  blank-but-present fields.
  """

  @doc """
  Builds the compact `request_options` map from caller opts.
  """
  @spec extract(:sync | :stream, keyword()) :: map()
  def extract(mode, opts) do
    provider_opts =
      case opts[:provider_options] do
        list when is_list(list) -> list
        _ -> []
      end

    %{
      temperature: opts[:temperature],
      top_p: opts[:top_p],
      top_k: opts[:top_k],
      max_tokens: opts[:max_tokens],
      frequency_penalty: opts[:frequency_penalty],
      presence_penalty: opts[:presence_penalty],
      stop_sequences: normalize_string_list(opts[:stop] || opts[:stop_sequences]),
      seed: opts[:seed],
      n: normalize_choice_count(opts[:n]),
      stream?: mode == :stream,
      encoding_formats: normalize_string_list(opts[:encoding_format]),
      conversation_id: telemetry_conversation_id(opts),
      service_tier: opts[:service_tier] || provider_opts[:service_tier]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_string_list(nil), do: nil
  defp normalize_string_list(value) when is_binary(value), do: [value]
  defp normalize_string_list(values) when is_list(values), do: values
  defp normalize_string_list(_), do: nil

  defp normalize_choice_count(nil), do: nil
  defp normalize_choice_count(value) when is_integer(value) and value >= 1, do: value
  defp normalize_choice_count(_), do: nil

  defp telemetry_conversation_id(opts) do
    case Keyword.fetch(opts, :telemetry) do
      {:ok, value} -> conversation_id_from(value)
      :error -> nil
    end
  end

  defp conversation_id_from(list) when is_list(list),
    do: conversation_id_from(Map.new(list))

  defp conversation_id_from(map) when is_map(map) do
    Map.get(map, :conversation_id, Map.get(map, "conversation_id"))
  end

  defp conversation_id_from(_), do: nil
end
