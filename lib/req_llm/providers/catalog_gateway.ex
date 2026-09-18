defmodule ReqLLM.Providers.CatalogGateway do
  @moduledoc """
  Runs OpenAI Chat Completions models for providers with LLMDB execution metadata.

  Registered provider modules take priority. This adapter only uses explicit
  model execution data and provider bearer authentication metadata.
  """

  use ReqLLM.Provider, id: :catalog_gateway, default_base_url: ""

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

  def prepare_request(operation, model, _input, _opts) do
    ProviderDispatch.unsupported(
      model,
      operation,
      "only chat and object operations are supported"
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
  @spec contract(LLMDB.Model.t(), :chat | :object, keyword()) ::
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
         {:ok, path} <- require_path(model, operation, execution) do
      {:ok,
       %{
         auth: auth,
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

  defp require_execution(
         model,
         operation,
         %{supported: true, family: "openai_chat_compatible", wire_protocol: "openai_chat"} =
           execution
       ) do
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

  defp require_execution(model, operation, _execution) do
    ProviderDispatch.unsupported(
      model,
      operation,
      "the model needs a supported #{if operation == :chat, do: :text, else: operation} execution contract with family openai_chat_compatible and wire protocol openai_chat"
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

  defp require_path(model, operation, %{path: path})
       when is_binary(path) and byte_size(path) > 1 do
    if String.starts_with?(path, "/") && !String.starts_with?(path, "//") &&
         !String.contains?(path, ["?", "#", "{", "}", "..", "\\"]) do
      {:ok, path}
    else
      ProviderDispatch.unsupported(
        model,
        operation,
        "the execution path must be a plain absolute path"
      )
    end
  end

  defp require_path(model, operation, _execution) do
    ProviderDispatch.unsupported(model, operation, "the execution path is missing")
  end

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
        Enum.find_value(env_names, &System.get_env/1)

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
end
