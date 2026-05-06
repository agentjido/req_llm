defmodule ReqLLM.Providers.Cohere do
  @moduledoc """
  Cohere provider implementation for reranking operations.
  """

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1, maybe_put: 3]

  use ReqLLM.Provider,
    id: :cohere,
    default_base_url: "https://api.cohere.com",
    default_env_key: "COHERE_API_KEY"

  @provider_schema [
    priority: [
      type: :non_neg_integer,
      doc:
        "Controls request priority. Lower numbers are handled sooner when the service is under load."
    ]
  ]

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
          [:operation, :model, :query, :documents, :top_n, :max_tokens_per_doc, :provider_options]

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
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.provider_model_id || model.id,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url())
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: [:rerank]"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    {api_key, extra_option_keys} =
      ReqLLM.Provider.Defaults.fetch_api_key_and_extra_options(__MODULE__, model, user_opts)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        [
          model: model.provider_model_id || model.id,
          auth: {:bearer, api_key}
        ] ++ user_opts
    )
    |> ReqLLM.Step.Retry.attach()
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    %{
      model: request.options[:model],
      query: request.options[:query],
      documents: request.options[:documents]
    }
    |> maybe_put(:top_n, request.options[:top_n])
    |> maybe_put(:max_tokens_per_doc, request.options[:max_tokens_per_doc])
    |> maybe_put(:priority, request.options[:priority])
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    body = build_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @impl ReqLLM.Provider
  def decode_response({req, %Req.Response{status: status} = resp}) when status in 200..299 do
    {req, %{resp | body: ensure_parsed_body(resp.body)}}
  end

  def decode_response({req, %Req.Response{status: status} = resp}) do
    error =
      ReqLLM.Error.API.Response.exception(
        reason: "Cohere API error",
        status: status,
        response_body: ensure_parsed_body(resp.body)
      )

    {req, error}
  end

  @impl ReqLLM.Provider
  def extract_usage(%{"meta" => meta}, _model) when is_map(meta) do
    tokens = Map.get(meta, "tokens") || %{}
    billed_units = Map.get(meta, "billed_units") || %{}
    search_units = Map.get(billed_units, "search_units")

    usage =
      tokens
      |> maybe_put(:billed_units, billed_units)
      |> maybe_put(:search_units, search_units)

    if usage == %{} do
      {:error, :no_usage_found}
    else
      {:ok, usage}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}
end
