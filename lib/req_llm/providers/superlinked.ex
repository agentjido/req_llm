defmodule ReqLLM.Providers.Superlinked do
  @moduledoc """
  Superlinked Inference Engine provider.

  Chat, streaming, tools, and dense embeddings use the OpenAI-compatible SIE
  endpoints. Reranking uses the native SIE score endpoint and returns ReqLLM's
  canonical rerank response.

  The hosted service uses `https://api.superlinked.com/v1` and bearer
  authentication from `SIE_API_KEY`. Pass `:base_url` for SIE Local or SIE
  Cluster.

  SIE can return `503 PROVISIONING` with `Retry-After` during a cold start.
  ReqLLM applies its bounded retry policy. Increase `:max_retries`,
  `:receive_timeout`, and `:total_timeout` when a deployment can take longer to
  become ready.
  """

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

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
           ReqLLM.Provider.Options.process(__MODULE__, :rerank, model, opts_with_input) do
      req_keys =
        supported_provider_options() ++
          [:operation, :model, :query, :documents, :top_n, :provider_options]

      provider_model_id = model.provider_model_id || model.id

      request =
        Req.new(
          [
            url: "/score/#{URI.encode(provider_model_id, &URI.char_unreserved?/1)}",
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: provider_model_id,
              base_url: Keyword.fetch!(processed_opts, :base_url)
            ]
        )
        |> attach(model, processed_opts)

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
          query: %{id: "query", text: options[:query]},
          items:
            options[:documents]
            |> Enum.with_index()
            |> Enum.map(fn {document, index} ->
              %{id: Integer.to_string(index), text: document}
            end)
        }

      _operation ->
        ReqLLM.Provider.Defaults.default_build_body(request)
    end
  end

  @impl ReqLLM.Provider
  def decode_response({%Req.Request{} = request, %Req.Response{} = response} = request_response) do
    case {request.options[:operation], response.status} do
      {:rerank, status} when status in 200..299 ->
        body = response.body |> ensure_parsed_body() |> normalize_score_response()
        {request, %{response | body: body}}

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
         ["Superlinked SIE does not accept :max_tokens_per_doc on its native score route"]}
    end
  end

  def translate_options(operation, model, opts) do
    ReqLLM.Provider.Defaults.default_translate_options(operation, model, opts)
  end

  defp normalize_score_response(%{"scores" => scores} = body) when is_list(scores) do
    results =
      Enum.map(scores, fn
        %{"item_id" => item_id, "score" => score} when is_binary(item_id) ->
          case Integer.parse(item_id) do
            {index, ""} -> %{"index" => index, "relevance_score" => score}
            _invalid -> %{}
          end

        _invalid ->
          %{}
      end)

    %{
      "id" => body["query_id"],
      "model" => body["model"],
      "results" => results,
      "usage" => body["usage"]
    }
  end

  defp normalize_score_response(body), do: body
end
