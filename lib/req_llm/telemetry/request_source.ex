defprotocol ReqLLM.Telemetry.RequestSource do
  @moduledoc """
  Extracts the upstream server (`address`, `port`, `path`) from a request
  representation for the telemetry context's `server` map.

  Implementations exist for `Req.Request` (the standard request path) and
  `ReqLLM.Streaming.Fixtures.HTTPContext` (the streaming-client wrapper).
  Anything else falls through to the `Any` implementation and returns `%{}`.
  """

  @fallback_to_any true

  @doc """
  Returns the server map for `source`. Keys are atoms; absent fields are
  dropped. Returns `%{}` when the source carries no usable URL.
  """
  @spec server(t) :: map()
  def server(source)
end

defimpl ReqLLM.Telemetry.RequestSource, for: Any do
  def server(_source), do: %{}
end

defimpl ReqLLM.Telemetry.RequestSource, for: Req.Request do
  def server(%{url: %URI{} = uri}) do
    %{}
    |> put_present(:address, uri.host)
    |> put_present(:port, uri.port)
    |> put_present(:path, uri.path)
  end

  def server(%{url: url}) when is_binary(url) do
    server(%Req.Request{url: URI.parse(url)})
  end

  def server(_source), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defimpl ReqLLM.Telemetry.RequestSource, for: ReqLLM.Streaming.Fixtures.HTTPContext do
  def server(%{url: url}) when is_binary(url) do
    ReqLLM.Telemetry.RequestSource.server(%Req.Request{url: url})
  end

  def server(_source), do: %{}
end
