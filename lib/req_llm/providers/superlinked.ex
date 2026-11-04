defmodule ReqLLM.Providers.Superlinked do
  @moduledoc """
  Superlinked Inference Engine provider.

  Chat, streaming, tools, and dense embeddings use the OpenAI-compatible SIE
  endpoints. Reranking uses the Cohere-compatible SIE v2 endpoint.

  The hosted service uses `https://api.superlinked.com/v1` and bearer
  authentication from `SIE_API_KEY`. Pass `:base_url` for SIE Local or SIE
  Cluster.

  SIE can return `503 PROVISIONING` with `Retry-After` during a cold start.
  ReqLLM applies its bounded retry policy. Increase `:max_retries`,
  `:receive_timeout`, and `:total_timeout` when a deployment can take longer to
  become ready.
  """

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1, maybe_put: 3]

  use ReqLLM.Provider,
    id: :superlinked,
    default_base_url: "https://api.superlinked.com/v1",
    default_env_key: "SIE_API_KEY"

  @provider_schema []

  @impl ReqLLM.Provider
  def prepare_request(:rerank, model_spec, %{query: query, documents: documents}, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         opts_with_input =
           opts
           |> Keyword.put(:query, query)
           |> Keyword.put(:documents, documents)
           |> Keyword.put(:operation, :rerank),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :rerank, model, opts_with_input),
         rerank_opts <-
           Keyword.update!(processed_opts, :base_url, &rerank_base_url/1) do
      req_keys =
        supported_provider_options() ++
          [:operation, :model, :query, :documents, :top_n, :provider_options]

      request =
        Req.new(
          [
            url: "/v2/rerank",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(rerank_opts, req_keys) ++
            [
              model: model.provider_model_id || model.id,
              base_url: Keyword.fetch!(rerank_opts, :base_url)
            ]
        )
        |> attach(model, rerank_opts)

      {:ok, request}
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def build_body(%Req.Request{options: options} = request) do
    case options[:operation] do
      :rerank ->
        %{
          model: options[:model],
          query: options[:query],
          documents: options[:documents]
        }
        |> maybe_put(:top_n, options[:top_n])

      _operation ->
        ReqLLM.Provider.Defaults.default_build_body(request)
    end
  end

  @impl ReqLLM.Provider
  def decode_response({%Req.Request{} = request, %Req.Response{} = response} = request_response) do
    case {request.options[:operation], response.status} do
      {:rerank, status} when status in 200..299 ->
        {request, %{response | body: ensure_parsed_body(response.body)}}

      {:rerank, _status} ->
        error =
          ReqLLM.Error.API.Request.exception(
            reason: "Superlinked API error",
            status: response.status,
            response_body: ensure_parsed_body(response.body),
            headers: response.headers
          )

        {request, error}

      {_operation, status} when status not in 200..299 ->
        error =
          ReqLLM.Error.API.Request.exception(
            reason: "Superlinked API error",
            status: response.status,
            response_body: ensure_parsed_body(response.body),
            headers: response.headers
          )

        {request, error}

      {_operation, _status} ->
        ReqLLM.Provider.Defaults.default_decode_response(request_response)
    end
  end

  @impl ReqLLM.Provider
  def translate_options(:rerank, _model, opts) do
    case Keyword.pop(opts, :max_tokens_per_doc) do
      {nil, translated} ->
        {translated, []}

      {_value, translated} ->
        {translated,
         ["Superlinked SIE does not accept a non-null :max_tokens_per_doc on /v2/rerank"]}
    end
  end

  def translate_options(operation, model, opts) do
    ReqLLM.Provider.Defaults.default_translate_options(operation, model, opts)
  end

  defp rerank_base_url(base_url) do
    uri = URI.parse(base_url)
    path = uri.path || ""
    normalized_path = path |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")

    %{uri | path: normalized_path}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end
end
