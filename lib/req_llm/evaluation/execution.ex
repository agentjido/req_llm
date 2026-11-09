defmodule ReqLLM.Evaluation.Execution do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.CatalogGateway

  @protocols ["typesafe_systemone", "openrouter_decisions", "openai_decisions"]

  @spec resolve(LLMDB.Model.t(), keyword()) :: {:ok, module()} | {:error, Exception.t()}
  def resolve(model, opts \\ []) do
    with {:ok, execution} <- contract(model) do
      case ReqLLM.Providers.get(model.provider) do
        {:ok, provider} ->
          if Code.ensure_loaded?(provider) and
               function_exported?(provider, :evaluation_protocols, 0) and
               execution.wire_protocol in provider.evaluation_protocols() do
            {:ok, provider}
          else
            unsupported(model, "the registered provider does not implement this protocol")
          end

        {:error, _} ->
          with {:ok, _contract} <- CatalogGateway.contract(model, :evaluate, opts) do
            {:ok, CatalogGateway}
          end
      end
    end
  end

  @spec contract(LLMDB.Model.t()) :: {:ok, map()} | {:error, Exception.t()}
  def contract(model) do
    execution = get_in(model.execution || %{}, [:evaluate])

    cond do
      get_in(model.capabilities || %{}, [:evaluate]) != true ->
        {:error,
         Parameter.exception(parameter: "#{LLMDB.Model.spec(model)} does not support evaluation")}

      not is_map(execution) or execution[:supported] != true ->
        unsupported(model, "an explicitly supported execution.evaluate contract is required")

      execution[:family] not in @protocols or execution[:wire_protocol] != execution[:family] ->
        unsupported(model, "unsupported decision family or wire protocol")

      execution[:transport] not in [nil, "http", "https"] ->
        unsupported(model, "only HTTP evaluation transport is supported")

      not valid_path?(execution[:path]) ->
        unsupported(model, "the execution path must be a plain absolute path")

      not is_binary(execution[:provider_model_id]) and
          execution[:family] != "typesafe_systemone" ->
        unsupported(model, "the execution provider_model_id is missing")

      true ->
        {:ok, execution}
    end
  end

  @spec context_supported?(LLMDB.Model.t()) :: boolean()
  def context_supported?(model) do
    match?({:ok, %{wire_protocol: "openai_decisions"}}, contract(model))
  end

  @spec endpoint(LLMDB.Model.t(), String.t(), keyword()) ::
          {:ok, %{base_url: String.t(), path: String.t()}} | {:error, Exception.t()}
  def endpoint(model, default_base_url, opts) do
    with {:ok, execution} <- contract(model) do
      base_url = opts[:base_url] || execution[:base_url] || model.base_url || default_base_url
      path = opts[:evaluate_path] || execution.path

      if valid_base_url?(base_url) and valid_path?(path) do
        {:ok, %{base_url: String.trim_trailing(base_url, "/"), path: path}}
      else
        unsupported(model, "a full HTTP base URL and plain absolute execution path are required")
      end
    end
  end

  @spec url(String.t(), String.t()) :: String.t()
  def url(base_url, path) do
    uri = URI.parse(base_url)
    prefix = String.trim_trailing(uri.path || "", "/")

    URI.to_string(%{uri | path: join_path(prefix, path)})
  end

  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) do
    is_binary(path) and byte_size(path) > 1 and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["?", "#", "{", "}", "..", "\\"])
  end

  defp join_path(prefix, path) do
    version = "/" <> List.last(String.split(prefix, "/"))

    cond do
      prefix != "" and (path == prefix or String.starts_with?(path, prefix <> "/")) ->
        path

      Regex.match?(~r{^/v\d+$}, version) and String.starts_with?(path, version <> "/") ->
        prefix <> String.replace_prefix(path, version, "")

      true ->
        prefix <> path
    end
  end

  defp valid_base_url?(base_url) when is_binary(base_url) do
    case URI.new(base_url) do
      {:ok, uri} ->
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
          uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
          not String.contains?(base_url, ["{", "}"])

      _ ->
        false
    end
  end

  defp valid_base_url?(_), do: false

  defp unsupported(model, reason) do
    family = get_in(model.execution || %{}, [:evaluate, :family])

    {:error,
     Parameter.exception(
       parameter:
         "No evaluation adapter for #{LLMDB.Model.spec(model)} (provider #{inspect(model.provider)}, execution family #{inspect(family)}): #{reason}"
     )}
  end
end
