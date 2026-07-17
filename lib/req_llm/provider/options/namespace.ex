defmodule ReqLLM.Provider.Options.Namespace do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Error.Validation.Error

  @type warning :: String.t()

  @spec normalize(module(), atom(), LLMDB.Model.t(), keyword()) ::
          {:ok, keyword(), [warning()]} | {:error, Exception.t()}
  def normalize(provider_mod, operation, %LLMDB.Model{} = model, opts)
      when is_atom(provider_mod) and is_atom(operation) and is_list(opts) do
    with :ok <- validate_keyword_options(opts),
         {:ok, normalized, warnings} <-
           normalize_container(provider_mod, operation, model.provider, opts) do
      apply_warning_policy(normalized, warnings, opts)
    end
  end

  def normalize(_provider_mod, _operation, _model, _opts) do
    invalid_parameter("options must be a keyword list")
  end

  @spec normalize!(module(), atom(), LLMDB.Model.t(), keyword()) :: {keyword(), [warning()]}
  def normalize!(provider_mod, operation, %LLMDB.Model{} = model, opts) do
    case normalize(provider_mod, operation, model, opts) do
      {:ok, normalized, warnings} -> {normalized, warnings}
      {:error, error} -> raise error
    end
  end

  defp normalize_container(provider_mod, operation, provider, opts) do
    case Keyword.get_values(opts, :provider_options) do
      [] ->
        {:ok, opts, []}

      [provider_options] ->
        normalize_provider_options(provider_mod, operation, provider, opts, provider_options)

      _provider_options ->
        invalid_parameter("request options contain provider_options more than once")
    end
  end

  defp normalize_provider_options(provider_mod, operation, provider, opts, provider_options) do
    with {:ok, entries} <- container_entries(provider_options),
         schema_keys <- provider_schema_keys(provider_mod),
         {:ok, flat_entries, namespace_entries} <-
           classify_entries(entries, provider, schema_keys),
         {:ok, namespace} <- one_namespace(namespace_entries, provider),
         {:ok, normalized, warnings} <-
           normalize_selected_namespace(
             namespace,
             flat_entries,
             provider_mod,
             operation,
             provider,
             opts
           ) do
      {:ok, normalized, warnings}
    else
      :legacy -> {:ok, opts, []}
      {:error, error} -> {:error, error}
    end
  end

  defp container_entries(options) when is_map(options), do: {:ok, Map.to_list(options)}

  defp container_entries(options) when is_list(options) do
    if Keyword.keyword?(options), do: {:ok, options}, else: :legacy
  end

  defp container_entries(_options), do: :legacy

  defp classify_entries(entries, provider, schema_keys) do
    known_providers = known_provider_ids(provider)

    entries
    |> Enum.reduce_while({[], []}, fn {key, value}, {flat, namespaces} ->
      cond do
        schema_key?(key, schema_keys) ->
          {:cont, {[{key, value} | flat], namespaces}}

        provider_key?(key, provider) ->
          {:cont, {flat, [{provider, value} | namespaces]}}

        foreign_provider = provider_key(key, known_providers) ->
          {:halt, foreign_namespace(foreign_provider, provider)}

        true ->
          {:cont, {[{key, value} | flat], namespaces}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {flat, namespaces} -> {:ok, Enum.reverse(flat), Enum.reverse(namespaces)}
    end
  end

  defp one_namespace([], _provider), do: {:ok, nil}
  defp one_namespace([{_namespace_provider, value}], _selected_provider), do: {:ok, value}

  defp one_namespace(_namespaces, provider) do
    invalid_parameter(
      "provider_options contains the #{inspect(provider)} namespace more than once"
    )
  end

  defp normalize_selected_namespace(nil, _flat, _provider_mod, _operation, _provider, opts),
    do: {:ok, opts, []}

  defp normalize_selected_namespace(
         namespace,
         flat,
         provider_mod,
         operation,
         provider,
         opts
       ) do
    schema_keys = provider_schema_keys(provider_mod)

    with {:ok, namespace_entries} <- namespace_entries(namespace, provider),
         {:ok, normalized_namespace} <-
           normalize_option_entries(namespace_entries, schema_keys, operation, provider),
         {:ok, normalized_flat} <-
           normalize_option_entries(flat, schema_keys, operation, provider),
         :ok <- reject_duplicate_keys(normalized_namespace, provider),
         :ok <- reject_duplicate_keys(normalized_flat, provider) do
      provider_collisions = colliding_keys(normalized_flat, normalized_namespace)

      merged_before_canonical =
        normalized_flat
        |> remove_keys(provider_collisions)
        |> Kernel.++(normalized_namespace)

      {merged, canonical_collisions} =
        remove_canonical_collisions(merged_before_canonical, operation, opts)

      normalized_opts = Keyword.put(opts, :provider_options, merged)

      warnings =
        mixed_shape_warnings(provider, normalized_flat, provider_collisions) ++
          canonical_collision_warnings(provider, canonical_collisions)

      {:ok, normalized_opts, warnings}
    end
  end

  defp namespace_entries(namespace, _provider) when is_map(namespace),
    do: {:ok, Map.to_list(namespace)}

  defp namespace_entries(namespace, provider) when is_list(namespace) do
    if Keyword.keyword?(namespace) do
      {:ok, namespace}
    else
      invalid_namespace_structure(provider)
    end
  end

  defp namespace_entries(_namespace, provider), do: invalid_namespace_structure(provider)

  defp normalize_option_entries(entries, schema_keys, operation, provider) do
    canonical_keys = canonical_option_keys(operation)
    schema_names = Map.new(schema_keys, &{Atom.to_string(&1), &1})

    entries
    |> Enum.reduce_while([], fn {key, value}, normalized ->
      case normalize_option_key(key, schema_keys, schema_names, canonical_keys, provider) do
        {:ok, normalized_key} -> {:cont, [{normalized_key, value} | normalized]}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      normalized -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp normalize_option_key(key, schema_keys, schema_names, canonical_keys, provider) do
    cond do
      is_atom(key) and key in schema_keys ->
        {:ok, key}

      is_atom(key) and schema_keys == [] ->
        {:ok, key}

      is_binary(key) and Map.has_key?(schema_names, key) ->
        {:ok, Map.fetch!(schema_names, key)}

      is_atom(key) and key in canonical_keys ->
        canonical_option_error(key)

      is_binary(key) ->
        case Enum.find(canonical_keys, &(Atom.to_string(&1) == key)) do
          nil -> unknown_provider_option(key, provider)
          canonical -> canonical_option_error(canonical)
        end

      true ->
        unknown_provider_option(key, provider)
    end
  end

  defp canonical_option_error(key) do
    invalid_parameter(
      "provider option #{inspect(key)} is canonical; pass it as a top-level request option"
    )
  end

  defp unknown_provider_option(key, provider) do
    invalid_parameter(
      "unknown provider option #{inspect(key)} in the #{inspect(provider)} namespace"
    )
  end

  defp reject_duplicate_keys(entries, provider) do
    duplicates =
      entries
      |> Enum.group_by(fn {key, _value} -> key end)
      |> Enum.filter(fn {_key, values} -> length(values) > 1 end)
      |> Enum.map(fn {key, _values} -> key end)
      |> Enum.sort()

    if duplicates == [] do
      :ok
    else
      invalid_parameter(
        "provider_options contains duplicate #{inspect(provider)} keys: #{format_keys(duplicates)}"
      )
    end
  end

  defp remove_canonical_collisions(namespace, operation, opts) do
    canonical_keys = MapSet.new(canonical_option_keys(operation))
    top_level_keys = MapSet.new(Keyword.keys(opts))

    collisions =
      namespace
      |> Keyword.keys()
      |> Enum.filter(&(MapSet.member?(canonical_keys, &1) and MapSet.member?(top_level_keys, &1)))
      |> Enum.uniq()
      |> Enum.sort()

    {Keyword.drop(namespace, collisions), collisions}
  end

  defp colliding_keys(left, right) do
    right_keys = MapSet.new(Keyword.keys(right))

    left
    |> Keyword.keys()
    |> Enum.filter(&MapSet.member?(right_keys, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp remove_keys(options, []), do: options
  defp remove_keys(options, keys), do: Keyword.drop(options, keys)

  defp mixed_shape_warnings(_provider, [], _collisions), do: []

  defp mixed_shape_warnings(provider, _flat, []) do
    [
      "Mixed legacy flat provider_options with the #{inspect(provider)} namespace; both forms were merged. " <>
        "Prefer provider_options: [#{provider}: [...]] without flat provider keys."
    ]
  end

  defp mixed_shape_warnings(provider, _flat, collisions) do
    [
      "Mixed legacy flat provider_options with the #{inspect(provider)} namespace; namespaced values took precedence for #{format_keys(collisions)}. " <>
        "Prefer provider_options: [#{provider}: [...]] without flat provider keys."
    ]
  end

  defp canonical_collision_warnings(_provider, []), do: []

  defp canonical_collision_warnings(provider, collisions) do
    [
      "Ignored namespaced #{inspect(provider)} values for #{format_keys(collisions)} because explicit top-level canonical options take precedence."
    ]
  end

  defp apply_warning_policy(normalized, [], _opts), do: {:ok, normalized, []}

  defp apply_warning_policy(normalized, warnings, opts) do
    case Keyword.get(opts, :on_unsupported, :warn) do
      :error ->
        {:error,
         Error.exception(
           tag: :unsupported_options,
           reason: Enum.join(warnings, "; "),
           context: []
         )}

      :ignore ->
        {:ok, normalized, []}

      _policy ->
        {:ok, normalized, warnings}
    end
  end

  defp canonical_option_keys(:chat), do: generation_option_keys()
  defp canonical_option_keys(:object), do: generation_option_keys()
  defp canonical_option_keys(:embedding), do: schema_keys(ReqLLM.Embedding.schema())
  defp canonical_option_keys(:image), do: schema_keys(ReqLLM.Images.schema())
  defp canonical_option_keys(:transcription), do: schema_keys(ReqLLM.Transcription.schema())
  defp canonical_option_keys(:speech), do: schema_keys(ReqLLM.Speech.schema())
  defp canonical_option_keys(:rerank), do: schema_keys(ReqLLM.Rerank.schema())
  defp canonical_option_keys(:ocr), do: schema_keys(ReqLLM.OCR.schema())
  defp canonical_option_keys(_operation), do: generation_option_keys()

  defp generation_option_keys do
    ReqLLM.Provider.Options.generation_schema()
    |> schema_keys()
  end

  defp schema_keys(%NimbleOptions{schema: schema}),
    do: schema |> Keyword.keys() |> Enum.reject(&(&1 == :provider_options))

  defp provider_schema_keys(provider_mod) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_mod.provider_schema().schema
      |> Keyword.keys()
    else
      []
    end
  end

  defp known_provider_ids(provider) do
    [provider | ReqLLM.Providers.list()]
    |> Enum.uniq()
  end

  defp schema_key?(key, schema_keys) when is_atom(key), do: key in schema_keys

  defp schema_key?(key, schema_keys) when is_binary(key),
    do: Enum.any?(schema_keys, &(Atom.to_string(&1) == key))

  defp schema_key?(_key, _schema_keys), do: false

  defp provider_key?(key, provider) when is_atom(key), do: key == provider
  defp provider_key?(key, provider) when is_binary(key), do: key == Atom.to_string(provider)
  defp provider_key?(_key, _provider), do: false

  defp provider_key(key, providers), do: Enum.find(providers, &provider_key?(key, &1))

  defp foreign_namespace(foreign_provider, selected_provider) do
    invalid_parameter(
      "provider_options namespace #{inspect(foreign_provider)} does not match selected provider #{inspect(selected_provider)}; use the #{inspect(selected_provider)} namespace"
    )
  end

  defp invalid_namespace_structure(provider) do
    invalid_parameter(
      "provider_options namespace #{inspect(provider)} must contain a keyword list or map"
    )
  end

  defp validate_keyword_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: invalid_parameter("options must be a keyword list")
  end

  defp format_keys(keys), do: Enum.map_join(keys, ", ", &inspect/1)

  defp invalid_parameter(message), do: {:error, Parameter.exception(parameter: message)}
end
