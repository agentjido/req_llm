defmodule ReqLLM.Providers.OpenAI.WebSocket do
  @moduledoc false

  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.Streaming.WebSocketSession

  @spec headers(LLMDB.Model.t(), keyword()) :: [{String.t(), String.t()}]
  def headers(%LLMDB.Model{} = model, opts) do
    custom_headers = ReqLLM.Provider.Utils.extract_custom_headers(opts[:req_http_options])

    ReqLLM.Providers.OpenAI.auth_header_list(
      ReqLLM.Providers.OpenAI.resolve_request_credential!(model, opts)
    ) ++
      custom_headers
  end

  @spec start_responses_session(LLMDB.Model.t(), keyword()) :: GenServer.on_start()
  def start_responses_session(%LLMDB.Model{} = model, opts \\ []) do
    WebSocketSession.start_link(responses_url(model, opts), headers: headers(model, opts))
  end

  @spec responses_url(LLMDB.Model.t(), keyword()) :: String.t()
  def responses_url(%LLMDB.Model{} = model, opts) do
    base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)
    websocket_url(base_url, "/responses")
  end

  @spec realtime_url(LLMDB.Model.t(), keyword()) :: String.t()
  def realtime_url(%LLMDB.Model{} = model, opts) do
    base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)
    websocket_url(base_url, "/realtime", model: model.provider_model_id || model.id)
  end

  @spec http_context(String.t(), [{String.t(), String.t()}]) :: HTTPContext.t()
  def http_context(url, headers) do
    HTTPContext.new(url, :get, Map.new(headers))
  end

  @spec websocket_url(String.t(), String.t(), keyword()) :: String.t()
  def websocket_url(base_url, path, query \\ []) do
    uri = URI.parse(base_url)
    encoded_query = encode_query(uri.query, query)

    uri
    |> Map.put(:scheme, websocket_scheme(uri.scheme))
    |> Map.put(:path, join_paths(uri.path, path))
    |> Map.put(:query, encoded_query)
    |> URI.to_string()
  end

  defp websocket_scheme("http"), do: "ws"
  defp websocket_scheme("https"), do: "wss"
  defp websocket_scheme("ws"), do: "ws"
  defp websocket_scheme("wss"), do: "wss"
  defp websocket_scheme(nil), do: "wss"
  defp websocket_scheme(other), do: other

  defp join_paths(nil, suffix), do: join_paths("", suffix)

  defp join_paths(prefix, suffix) do
    trimmed_prefix = String.trim_trailing(prefix, "/")
    trimmed_suffix = String.trim_leading(suffix, "/")

    case {trimmed_prefix, trimmed_suffix} do
      {"", ""} -> "/"
      {"", suffix_path} -> "/" <> suffix_path
      {prefix_path, ""} -> prefix_path
      {prefix_path, suffix_path} -> prefix_path <> "/" <> suffix_path
    end
  end

  defp encode_query(nil, []), do: nil
  defp encode_query(query, []), do: query

  defp encode_query(query, values) do
    query
    |> URI.decode_query()
    |> Map.merge(Map.new(values, fn {key, value} -> {to_string(key), value} end))
    |> URI.encode_query()
  rescue
    _ -> URI.encode_query(values)
  end
end
