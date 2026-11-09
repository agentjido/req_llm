defmodule ReqLLM.Providers.CatalogGateway do
  @moduledoc """
  Runs shared wire protocols for providers with LLMDB execution metadata.

  Registered provider modules take priority. This adapter only uses explicit
  model execution data and provider bearer authentication metadata. It supports
  OpenAI Chat Completions, Cohere-compatible reranking, and decision evaluation.
  """

  use ReqLLM.Provider, id: :catalog_gateway, default_base_url: ""

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.ProviderDispatch

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) when operation in [:chat, :object] do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, contract} <- contract(model, operation, opts),
         {:ok, _api_key} <- credential(model.provider, contract.auth, opts) do
      Defaults.prepare_request(
        __MODULE__,
        operation,
        model,
        input,
        Keyword.put(opts, :base_url, contract.base_url)
      )
    end
  end

  def prepare_request(:rerank, model_spec, %{query: query, documents: documents}, opts) do
    with {:ok, model} <- resolve_model(model_spec),
         {:ok, contract} <- contract(model, :rerank, opts),
         {:ok, _api_key} <- credential(model.provider, contract.auth, opts),
         opts_with_input =
           opts
           |> Keyword.put(:query, query)
           |> Keyword.put(:documents, documents)
           |> Keyword.put(:operation, :rerank),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :rerank, model, opts_with_input) do
      req_keys = [
        :operation,
        :model,
        :query,
        :documents,
        :top_n,
        :max_tokens_per_doc,
        :rerank_path,
        :provider_options
      ]

      processed_opts =
        processed_opts
        |> Keyword.put(:base_url, contract.base_url)
        |> Keyword.put(:rerank_path, contract.path)

      request =
        Req.new(
          [
            url: contract.path,
            method: :post,
            receive_timeout: Keyword.get(processed_opts, :receive_timeout, 30_000)
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [model: contract.provider_model_id, base_url: contract.base_url]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:evaluate, model_spec, input, opts) do
    with {:ok, model} <- resolve_model(model_spec),
         {:ok, contract} <- contract(model, :evaluate, opts),
         {:ok, api_key} <- credential(model.provider, contract.auth, opts) do
      ReqLLM.Evaluation.Protocol.prepare_request(model, input, opts, contract, api_key)
    end
  end

  def prepare_request(operation, model, _input, _opts) do
    ProviderDispatch.unsupported(
      model,
      operation,
      "only chat, object, rerank, and evaluate operations are supported"
    )
  end

  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    operation = Keyword.get(opts, :operation, :chat)
    {:ok, contract} = contract(model, operation, opts)
    api_key = credential!(model.provider, contract.auth, opts)
    wire_model = %{model | provider_model_id: contract.provider_model_id}
    request = %{request | url: URI.parse(contract.path)}
    opts = Keyword.put(opts, :base_url, contract.base_url)

    Defaults.attach_with_api_key(
      __MODULE__,
      request,
      wire_model,
      opts,
      api_key,
      Defaults.extra_option_keys(__MODULE__)
    )
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    operation = Keyword.get(opts, :operation, :chat)

    with {:ok, contract} <- contract(model, operation, Keyword.put(opts, :stream, true)),
         {:ok, api_key} <- credential(model.provider, contract.auth, opts) do
      wire_model = %{
        model
        | provider_model_id: contract.provider_model_id,
          base_url: contract.base_url
      }

      processed_opts =
        opts
        |> Keyword.put(:api_key, api_key)
        |> Keyword.put(:base_url, contract.base_url)
        |> then(
          &ReqLLM.Provider.Options.process_stream!(__MODULE__, operation, wire_model, context, &1)
        )

      Defaults.default_attach_stream(__MODULE__, wire_model, context, processed_opts, finch_name)
    end
  rescue
    error -> {:error, error}
  end

  def streaming_http(model, api_key, opts) do
    {:ok, contract} = contract(model, Keyword.get(opts, :operation, :chat), opts)

    %{
      path: contract.path,
      headers: [
        {"Authorization", "Bearer " <> api_key},
        {"Content-Type", "application/json"}
      ]
    }
  end

  @doc false
  @spec contract(LLMDB.Model.t(), :chat | :object | :rerank | :evaluate, keyword()) ::
          {:ok, map()} | {:error, Exception.t()}
  def contract(%LLMDB.Model{} = model, operation, opts) do
    execution_operation = if operation == :chat, do: :text, else: operation
    execution = get_in(model.execution || %{}, [execution_operation])

    with :ok <- require_executable_model(model, operation),
         :ok <- require_execution(model, operation, execution),
         :ok <- require_streaming(model, operation, opts),
         {:ok, provider} <- fetch_provider(model, operation),
         {:ok, auth} <- require_bearer_auth(model, operation, provider),
         :ok <- require_plain_runtime(model, operation, provider),
         {:ok, base_url} <- require_base_url(model, operation, execution, provider, opts),
         {:ok, path} <- require_path(model, operation, execution, opts) do
      {:ok,
       %{
         auth: auth,
         wire_protocol: Map.get(execution, :wire_protocol),
         base_url: base_url,
         path: path,
         provider_model_id:
           Map.get(execution, :provider_model_id) || model.provider_model_id || model.id
       }}
    end
  end

  defp require_executable_model(%{catalog_only: true} = model, operation) do
    ProviderDispatch.unsupported(model, operation, "the model is catalog only")
  end

  defp require_executable_model(_model, _operation), do: :ok

  defp require_execution(model, :evaluate, _execution) do
    case ReqLLM.Evaluation.Execution.contract(model) do
      {:ok, _execution} -> :ok
      {:error, _} = error -> error
    end
  end

  defp require_execution(
         model,
         operation,
         %{supported: true, family: "openai_chat_compatible", wire_protocol: "openai_chat"} =
           execution
       )
       when operation in [:chat, :object] do
    if Map.get(execution, :transport) in [nil, "http", "https"] do
      :ok
    else
      ProviderDispatch.unsupported(
        model,
        operation,
        "transport #{inspect(Map.get(execution, :transport))} is not supported"
      )
    end
  end

  defp require_execution(
         model,
         :rerank,
         %{
           supported: true,
           family: "cohere_rerank_compatible",
           wire_protocol: "cohere_rerank"
         } = execution
       ) do
    if Map.get(execution, :transport) in [nil, "http", "https"] do
      :ok
    else
      ProviderDispatch.unsupported(
        model,
        :rerank,
        "transport #{inspect(Map.get(execution, :transport))} is not supported"
      )
    end
  end

  defp require_execution(model, operation, _execution) do
    requirement =
      case operation do
        :rerank ->
          "rerank execution contract with family cohere_rerank_compatible and wire protocol cohere_rerank"

        _other ->
          "#{if operation == :chat, do: :text, else: operation} execution contract with family openai_chat_compatible and wire protocol openai_chat"
      end

    ProviderDispatch.unsupported(
      model,
      operation,
      "the model needs a supported #{requirement}"
    )
  end

  defp require_streaming(model, operation, opts) do
    if opts[:stream] == true and get_in(model.capabilities || %{}, [:streaming, :text]) != true do
      ProviderDispatch.unsupported(
        model,
        operation,
        "the model does not declare text streaming support"
      )
    else
      :ok
    end
  end

  defp fetch_provider(model, operation) do
    case LLMDB.provider(model.provider) do
      {:ok, %{catalog_only: false, runtime: runtime}} when is_map(runtime) ->
        {:ok, runtime}

      _ ->
        ProviderDispatch.unsupported(
          model,
          operation,
          "the provider needs executable LLMDB runtime metadata"
        )
    end
  end

  defp require_bearer_auth(_model, _operation, %{auth: %{type: "bearer"} = auth}) do
    {:ok, auth}
  end

  defp require_bearer_auth(model, operation, _runtime) do
    ProviderDispatch.unsupported(model, operation, "only bearer authentication is supported")
  end

  defp require_plain_runtime(model, operation, runtime) do
    auth_headers = get_in(runtime, [:auth, :headers]) || []

    if auth_headers == [] && Map.get(runtime, :default_headers, %{}) == %{} &&
         Map.get(runtime, :default_query, %{}) == %{} do
      :ok
    else
      ProviderDispatch.unsupported(
        model,
        operation,
        "provider runtime headers or query parameters need a dedicated adapter"
      )
    end
  end

  defp require_base_url(model, operation, execution, runtime, opts) do
    base_url =
      opts[:base_url] || Map.get(execution, :base_url) || model.base_url ||
        Map.get(runtime, :base_url)

    uri =
      case is_binary(base_url) && URI.new(base_url) do
        {:ok, parsed_uri} -> parsed_uri
        _ -> nil
      end

    if uri && uri.scheme in ["https", "http"] && is_binary(uri.host) &&
         uri.host != "" && uri.userinfo == nil && uri.query == nil && uri.fragment == nil &&
         !String.contains?(base_url, ["{", "}"]) do
      {:ok, String.trim_trailing(base_url, "/")}
    else
      ProviderDispatch.unsupported(model, operation, "a full HTTP base URL is required")
    end
  end

  defp require_path(model, operation, execution, opts) do
    path =
      case operation do
        :evaluate -> opts[:evaluate_path] || Map.get(execution, :path)
        _ -> opts[:rerank_path] || Map.get(execution, :path)
      end

    cond do
      is_binary(path) && byte_size(path) > 1 && String.starts_with?(path, "/") &&
        !String.starts_with?(path, "//") &&
          !String.contains?(path, ["?", "#", "{", "}", "..", "\\"]) ->
        {:ok, path}

      is_nil(path) ->
        ProviderDispatch.unsupported(model, operation, "the execution path is missing")

      true ->
        ProviderDispatch.unsupported(
          model,
          operation,
          "the execution path must be a plain absolute path"
        )
    end
  end

  @impl ReqLLM.Provider
  def build_body(%Req.Request{options: %{operation: :rerank}} = request) do
    ReqLLM.Providers.CohereRerank.build_body(request)
  end

  def build_body(request), do: Defaults.default_build_body(request)

  @impl ReqLLM.Provider
  def decode_response(
        {%Req.Request{options: %{operation: :rerank}} = request,
         %Req.Response{status: status} = response}
      )
      when status in 200..299 do
    {request, %{response | body: ensure_parsed_body(response.body)}}
  end

  def decode_response(
        {%Req.Request{options: %{operation: :rerank}} = request,
         %Req.Response{status: status} = response}
      ) do
    error =
      ReqLLM.Error.API.Response.exception(
        reason: "Cohere-compatible rerank API error",
        status: status,
        response_body: ensure_parsed_body(response.body)
      )

    {request, error}
  end

  def decode_response(request_response), do: Defaults.default_decode_response(request_response)

  @impl ReqLLM.Provider
  def extract_usage(%{"meta" => _meta} = body, _model) do
    ReqLLM.Providers.CohereRerank.extract_usage(body)
  end

  def extract_usage(body, model), do: Defaults.default_extract_usage(body, model)

  defp credential!(provider, auth, opts) do
    case credential(provider, auth, opts) do
      {:ok, api_key} -> api_key
      {:error, error} -> raise error
    end
  end

  defp credential(provider, auth, opts) do
    env_names = Map.get(auth, :env) || []

    api_key =
      opts[:api_key] ||
        Application.get_env(:req_llm, ReqLLM.Keys.config_key(provider)) ||
        Enum.find_value(env_names, fn name ->
          case System.get_env(name) do
            key when is_binary(key) and key != "" -> key
            _ -> nil
          end
        end)

    if is_binary(api_key) && api_key != "" do
      {:ok, api_key}
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter:
           "API key for #{provider} is missing; set :api_key, config :req_llm, #{ReqLLM.Keys.config_key(provider)}, or one of #{inspect(env_names)}"
       )}
    end
  end

  defp resolve_model(%LLMDB.Model{} = model), do: {:ok, model}
  defp resolve_model(model_spec), do: ReqLLM.model(model_spec)
end
