defmodule ReqLLM.CallMetadata do
  @moduledoc false

  alias ReqLLM.Response.Projection

  @cost_keys [:cost, :input_cost, :output_cost, :reasoning_cost, :total_cost]
  @provider_request_id_headers [
    "x-request-id",
    "request-id",
    "x-correlation-id",
    "x-amzn-requestid"
  ]

  @spec from_req_response(Req.Response.t(), LLMDB.Model.t(), keyword()) :: map()
  def from_req_response(%Req.Response{} = response, %LLMDB.Model{} = model, opts \\ []) do
    sources = metadata_sources(response, opts)

    %{
      model: model.provider_model_id || model.id || model.model,
      provider: model.provider
    }
    |> put_available(:status, status(response, opts))
    |> put_available(:request_id, req_llm_request_id(response))
    |> put_available(:response_id, response_id(response.body))
    |> put_available(:usage, usage(response))
    |> put_available(:warnings, Projection.warnings(sources))
    |> put_available(:timings, timings(response, opts))
    |> put_available(:provider_metadata, provider_metadata(response))
  end

  defp metadata_sources(response, opts) do
    req_llm_private = Map.get(response.private, :req_llm, %{})
    request_plan = Map.get(response.private, :req_llm_request_plan, %{})

    [response.body, response.private, req_llm_private, request_plan] ++
      Keyword.get(opts, :sensitive_sources, [])
  end

  defp status(response, opts) do
    if Keyword.get(opts, :include_status, false), do: response.status
  end

  defp req_llm_request_id(response) do
    case get_in(response.private, [:req_llm, :request_id]) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _other -> nil
    end
  end

  defp response_id(body) when is_map(body) do
    case Map.get(body, :id) || Map.get(body, "id") do
      response_id when is_binary(response_id) and response_id != "" -> response_id
      _other -> nil
    end
  end

  defp response_id(_body), do: nil

  defp usage(response) do
    case get_in(response.private, [:req_llm, :usage]) do
      %{tokens: tokens} = details when is_map(tokens) ->
        details
        |> Map.take(@cost_keys)
        |> reject_unavailable()
        |> then(&Map.merge(tokens, &1))

      _other ->
        nil
    end
  end

  defp timings(response, opts) do
    opts
    |> Keyword.get(:timings)
    |> Kernel.||(%{})
    |> put_available(:provider_ms, provider_processing_ms(response.headers))
    |> reject_unavailable()
    |> non_empty_map()
  end

  defp provider_processing_ms(headers) do
    headers
    |> first_header(["openai-processing-ms", "x-envoy-upstream-service-time"])
    |> parse_number()
  end

  defp provider_metadata(response) do
    response.body
    |> body_provider_metadata()
    |> put_available(:request_id, provider_request_id(response))
    |> reject_unavailable()
    |> non_empty_map()
    |> case do
      nil -> nil
      metadata -> Projection.safe_metadata(metadata)
    end
  end

  defp body_provider_metadata(body) when is_map(body) do
    case Map.get(body, :provider_metadata) || Map.get(body, "provider_metadata") do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp body_provider_metadata(_body), do: %{}

  defp provider_request_id(response) do
    first_header(response.headers, @provider_request_id_headers) || body_request_id(response.body)
  end

  defp body_request_id(body) when is_map(body) do
    case Map.get(body, :request_id) || Map.get(body, "request_id") do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _other -> nil
    end
  end

  defp body_request_id(_body), do: nil

  defp first_header(headers, names) do
    Enum.find_value(names, &header_value(headers, &1))
  end

  defp header_value(headers, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: normalize_header_value(value)
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == name, do: normalize_header_value(value)

      _other ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp normalize_header_value([value | _rest]), do: normalize_header_value(value)

  defp normalize_header_value(value) when is_binary(value) and value != "", do: value
  defp normalize_header_value(_value), do: nil

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp parse_number(value) when is_number(value), do: value
  defp parse_number(_value), do: nil

  defp put_available(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp put_available(map, key, value), do: Map.put(map, key, value)

  defp reject_unavailable(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map
end
