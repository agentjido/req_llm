defmodule ReqLLM.Provider.Options.Defaults do
  @moduledoc false

  alias ReqLLM.Provider.Options
  alias ReqLLM.Provider.Options.Namespace

  @spec merge(module(), atom(), LLMDB.Model.t(), keyword()) ::
          {:ok, keyword(), [String.t()]} | {:error, Exception.t()}
  def merge(provider_mod, operation, model, opts) do
    config = Application.get_env(:req_llm, model.provider, [])
    defaults = [value(config, :provider_options), value(model.extra, :provider_options)]

    if Enum.all?(defaults, &is_nil/1) do
      {:ok, opts, []}
    else
      merge_layers(defaults, provider_mod, operation, model, opts)
    end
  end

  defp merge_layers(layers, provider_mod, operation, model, opts) do
    with {:ok, defaults, warnings} <-
           Enum.reduce_while(layers, {:ok, [], []}, fn layer, {:ok, acc, warnings} ->
             case normalize_layer(layer, provider_mod, operation, model, opts) do
               {:ok, values, more_warnings} ->
                 {:cont, {:ok, Keyword.merge(acc, values), warnings ++ more_warnings}}

               {:error, _} = error ->
                 {:halt, error}
             end
           end),
         {:ok, explicit} <- Options.normalize_flat_provider_options(provider_mod, opts),
         {:ok, explicit_values} <- provider_values(explicit) do
      defaults = Keyword.drop(defaults, Keyword.keys(explicit))
      values = Keyword.merge(defaults, explicit_values)
      {:ok, Keyword.put(explicit, :provider_options, values), warnings}
    end
  end

  defp normalize_layer(nil, _provider_mod, _operation, _model, _opts), do: {:ok, [], []}

  defp normalize_layer(layer, provider_mod, operation, model, opts) do
    with {:ok, normalized, warnings} <-
           Namespace.normalize_explicit(
             provider_mod,
             operation,
             model,
             Keyword.put(opts, :provider_options, layer)
           ),
         {:ok, normalized} <- Options.normalize_flat_provider_options(provider_mod, normalized),
         {:ok, values} <- provider_values(normalized) do
      {:ok, values, warnings}
    end
  end

  defp provider_values(opts) do
    values = Keyword.get(opts, :provider_options, [])

    if is_list(values) and Keyword.keyword?(values) do
      {:ok, values}
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "provider options and defaults must be keyword lists or maps"
       )}
    end
  end

  defp value(container, key) when is_list(container), do: Keyword.get(container, key)

  defp value(container, key) when is_map(container) do
    Map.get(container, key, Map.get(container, Atom.to_string(key)))
  end

  defp value(_container, _key), do: nil
end
