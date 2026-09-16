defmodule ReqLLM.Providers.OpenAICompatible do
  @moduledoc """
  Shared Chat Completions adapter for cataloged OpenAI-compatible providers.

  A model must declare the operation's execution family in LLMDB. The provider
  must declare an API URL and bearer authentication. A dedicated provider module
  takes precedence over this adapter.
  """

  use ReqLLM.Provider,
    id: :openai_compatible,
    default_base_url: ""

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Provider.Defaults

  def path, do: "/chat/completions"

  @spec validate(LLMDB.Model.t(), LLMDB.Provider.t(), atom()) ::
          :ok | {:error, Parameter.t()}
  def validate(%LLMDB.Model{} = model, %LLMDB.Provider{} = provider, operation) do
    execution = execution_for(model, operation)
    runtime = provider.runtime || %{}
    auth = runtime[:auth] || %{}

    cond do
      model.catalog_only == true or provider.catalog_only == true ->
        invalid(model, "the catalog entry is not executable")

      not compatible_execution?(execution) ->
        invalid(model, "#{operation} does not declare OpenAI Chat Completions compatibility")

      auth[:type] != "bearer" ->
        invalid(model, "the provider must declare bearer authentication")

      not valid_env?(auth[:env]) ->
        invalid(model, "the provider must declare an API key environment variable")

      not valid_url?(runtime[:base_url]) ->
        invalid(model, "the provider must declare an HTTP API base URL")

      not empty_map?(runtime[:default_headers]) or not empty_map?(runtime[:default_query]) ->
        invalid(model, "the provider requires HTTP defaults outside the shared adapter")

      true ->
        :ok
    end
  end

  def accepts_provider?(provider_id) when is_atom(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, %LLMDB.Provider{runtime: %{auth: %{type: "bearer"}}}} -> true
      _ -> false
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider} <- LLMDB.provider(model.provider),
         :ok <- validate(model, provider, operation),
         {:ok, base_url} <- base_url(model, provider, operation, opts) do
      Defaults.prepare_request(
        __MODULE__,
        operation,
        model,
        input,
        Keyword.put(opts, :base_url, base_url)
      )
    end
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    operation = Keyword.get(opts, :operation, :chat)

    with {:ok, provider} <- LLMDB.provider(model.provider),
         :ok <- validate(model, provider, operation),
         {:ok, base_url} <- base_url(model, provider, operation, opts) do
      super(model, context, Keyword.put(opts, :base_url, base_url), finch_name)
    end
  end

  defp execution_for(model, operation) do
    key = if operation == :chat, do: :text, else: operation
    Map.get(model.execution || %{}, key)
  end

  defp compatible_execution?(
         %{
           supported: true,
           family: "openai_chat_compatible",
           wire_protocol: "openai_chat"
         } = execution
       ) do
    execution[:path] in [nil, "/chat/completions"]
  end

  defp compatible_execution?(_execution), do: false

  defp valid_env?([env | _]) when is_binary(env), do: env != ""
  defp valid_env?(_env), do: false

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_url?(_url), do: false

  defp empty_map?(nil), do: true
  defp empty_map?(map) when is_map(map), do: map_size(map) == 0
  defp empty_map?(_value), do: false

  defp base_url(model, provider, operation, opts) do
    execution = execution_for(model, operation)

    url =
      opts[:base_url] || execution[:base_url] || model.base_url || provider.runtime[:base_url]

    if valid_url?(url) do
      {:ok, url}
    else
      invalid(model, "the request needs an HTTP API base URL")
    end
  end

  defp invalid(model, reason) do
    {:error,
     Parameter.exception(
       parameter: "#{model.provider}:#{model.id} cannot use the shared OpenAI adapter: #{reason}"
     )}
  end
end
