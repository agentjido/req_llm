defmodule ReqLLM.Test.ModelMatrix do
  @moduledoc """
  Declarative model selection for coverage tests.

  Test-only module that replaces tier-based selection with explicit
  configuration and flexible environment variable patterns.

  ## Environment Variables

  - `REQ_LLM_MODELS` - Model selection pattern (default: from config)
    - `"all"` - All available models
    - `"anthropic:*"` - All models from Anthropic
    - `"openai:gpt-4o,anthropic:claude-3-5-sonnet"` - Specific models
  - `REQ_LLM_OPERATION` - Operation type filter (default: text)
    - `"text"` - Text generation models (default)
    - `"embedding"` - Embedding models only
  - `REQ_LLM_SAMPLE` - Number of models to sample per provider
  - `REQ_LLM_EXCLUDE` - Models to exclude (space or comma separated)

  ## Examples

      # Get selected model specs (text models, default)
      specs = ModelMatrix.selected_specs()
      # => ["openai:gpt-4o", "anthropic:claude-3-5-sonnet", ...]

      # Get embedding models only
      specs = ModelMatrix.selected_specs(operation: :embedding)
      # => ["openai:text-embedding-3-small", "google:text-embedding-004", ...]

      # Get models for specific provider
      specs = ModelMatrix.models_for_provider(:anthropic)
      # => ["anthropic:claude-3-5-sonnet", "anthropic:claude-3-haiku", ...]

      # Get embedding models for specific provider
      specs = ModelMatrix.models_for_provider(:google, operation: :embedding)
      # => ["google:text-embedding-004", "google:gemini-embedding-001"]
  """

  @type operation :: :text | :embedding
  @type opts :: [
          env: %{optional(String.t()) => String.t() | nil},
          registry: module(),
          operation: operation()
        ]

  @doc """
  Returns list of model specs to test based on configuration.

  Selection priority:
  1. opts[:operation] or opts[:env]["REQ_LLM_OPERATION"] determines model set (:text or :embedding)
  2. opts[:env] map or REQ_LLM_MODELS environment variable for pattern matching
  3. Default models from config for the specified operation
  4. Applies sampling if opts[:env]["REQ_LLM_SAMPLE"] or REQ_LLM_SAMPLE is set
  5. Applies exclusions if opts[:env]["REQ_LLM_EXCLUDE"] or REQ_LLM_EXCLUDE is set

  ## Options

    * `:env` - Map of environment variables to use instead of System.get_env
    * `:registry` - Registry module to use for listing models (default: uses LLMDB directly)
    * `:operation` - Operation type (:text or :embedding, default: :text)

  ## Examples

      # Default models (text generation)
      ModelMatrix.selected_specs()
      # => ["openai:gpt-4o", "openai:gpt-4o-mini", ...]

      # Embedding models
      ModelMatrix.selected_specs(operation: :embedding)
      # => ["openai:text-embedding-3-small", "google:text-embedding-004", ...]

      # Pattern-based
      ModelMatrix.selected_specs(env: %{"REQ_LLM_MODELS" => "anthropic:*"})
      # => All Anthropic models
  """
  @spec selected_specs() :: [binary()]
  def selected_specs, do: selected_specs([])

  @spec selected_specs(opts()) :: [binary()]
  def selected_specs(opts) do
    env = Keyword.get(opts, :env, %{})
    registry = Keyword.get(opts, :registry)

    operation =
      parse_operation(Keyword.get(opts, :operation) || get_env_value(env, "REQ_LLM_OPERATION"))

    pattern = get_env_value(env, "REQ_LLM_MODELS")
    sample = get_env_value(env, "REQ_LLM_SAMPLE")
    exclude = get_env_value(env, "REQ_LLM_EXCLUDE")

    resolve_base_selection(pattern, operation, registry)
    |> maybe_sample(sample)
    |> maybe_exclude(exclude)
    |> Enum.sort()
  end

  @doc """
  Returns models for a specific provider.

  Filters selected_specs() to only include models from the given provider.

  ## Examples

      ModelMatrix.models_for_provider(:anthropic)
      # => ["anthropic:claude-3-5-sonnet", ...]
  """
  @spec models_for_provider(atom()) :: [binary()]
  def models_for_provider(provider), do: models_for_provider(provider, [])

  @spec models_for_provider(atom(), opts()) :: [binary()]
  def models_for_provider(provider, opts) when is_atom(provider) do
    provider_prefix = "#{provider}:"

    selected_specs(opts)
    |> Enum.filter(&String.starts_with?(&1, provider_prefix))
  end

  defp get_env_value(env_map, key) do
    Map.get(env_map, key) || System.get_env(key)
  end

  defp parse_operation(nil), do: :text
  defp parse_operation(:text), do: :text
  defp parse_operation(:embedding), do: :embedding
  defp parse_operation("text"), do: :text
  defp parse_operation("embedding"), do: :embedding
  defp parse_operation(_), do: :text

  defp resolve_base_selection(pattern, operation, registry) do
    case pattern do
      "all" ->
        all_model_specs(registry)

      nil ->
        default_model_specs(operation, registry)

      pattern_str ->
        resolve_patterns(pattern_str, registry)
    end
  end

  defp resolve_patterns(pattern_string, registry) do
    pattern_string
    |> String.split([",", " "], trim: true)
    |> Enum.flat_map(&expand_pattern(&1, registry))
    |> Enum.uniq()
  end

  defp expand_pattern("*:*", registry), do: all_model_specs(registry)
  defp expand_pattern("all", registry), do: all_model_specs(registry)

  defp expand_pattern(pattern, registry) do
    case String.split(pattern, ":", parts: 2) do
      [provider, "*"] ->
        expand_provider_wildcard(String.to_atom(provider), registry)

      [_provider, _model] ->
        [pattern]

      _ ->
        []
    end
  end

  defp expand_provider_wildcard(provider, nil) do
    models = LLMDB.models(provider)
    Enum.map(models, &"#{provider}:#{&1.id}")
  end

  defp expand_provider_wildcard(provider, registry) do
    case registry.list_models(provider) do
      {:ok, models} -> Enum.map(models, &"#{provider}:#{&1.id}")
      {:error, _} -> []
    end
  end

  defp all_model_specs(registry) do
    allowed_model_specs(registry)
  end

  defp allowed_model_specs(nil) do
    # Get providers that have both implementation and models
    implemented_providers = ReqLLM.Providers.list() |> MapSet.new()

    llmdb_providers =
      LLMDB.providers()
      |> MapSet.new(& &1.id)

    providers = MapSet.intersection(implemented_providers, llmdb_providers)

    providers
    |> Enum.flat_map(fn provider ->
      models = LLMDB.models(provider)
      Enum.map(models, &"#{provider}:#{&1.id}")
    end)
  end

  defp allowed_model_specs(registry) do
    registry.list_providers()
    |> Enum.flat_map(fn provider ->
      case registry.list_models(provider) do
        {:ok, models} -> Enum.map(models, &"#{provider}:#{&1.id}")
        {:error, _} -> []
      end
    end)
  end

  defp default_model_specs(:text, registry) do
    configured = Application.get_env(:req_llm, :sample_text_models)

    if configured && not Enum.empty?(configured) do
      configured
    else
      auto_pick_from_allowed(registry)
    end
  end

  defp default_model_specs(:embedding, _registry) do
    Application.get_env(:req_llm, :sample_embedding_models) || []
  end

  defp auto_pick_from_allowed(registry) do
    per_provider = Application.get_env(:req_llm, :test_sample_per_provider, 1)

    resolve_allowed_specs(registry)
    |> Enum.group_by(&extract_provider/1)
    |> Enum.flat_map(fn {_provider, specs} ->
      specs
      |> Enum.sort()
      |> Enum.take(per_provider)
    end)
  end

  defp resolve_allowed_specs(nil) do
    ReqLLM.Providers.list()
    |> Enum.flat_map(fn provider ->
      models = LLMDB.models(provider)
      Enum.map(models, fn model -> LLMDB.Model.spec(model) end)
    end)
    |> Enum.sort()
  end

  defp resolve_allowed_specs(registry) do
    registry.list_providers()
    |> Enum.flat_map(fn provider ->
      case registry.list_models(provider) do
        {:ok, models} -> Enum.map(models, &"#{provider}:#{&1.id}")
        {:error, _} -> []
      end
    end)
    |> Enum.sort()
  end

  defp maybe_sample(specs, nil), do: specs

  defp maybe_sample(specs, sample_str) do
    case Integer.parse(sample_str) do
      {n, _} when n > 0 -> sample_by_provider(specs, n)
      _ -> specs
    end
  end

  defp sample_by_provider(specs, n) do
    specs
    |> Enum.group_by(&extract_provider/1)
    |> Enum.flat_map(fn {_provider, provider_specs} ->
      provider_specs
      |> Enum.with_index()
      |> Enum.filter(fn {_spec, idx} -> rem(idx, 3) == 0 end)
      |> Enum.map(fn {spec, _idx} -> spec end)
      |> Enum.take(n)
    end)
  end

  defp maybe_exclude(specs, nil), do: specs

  defp maybe_exclude(specs, exclude_str) do
    exclusions =
      exclude_str
      |> String.split([",", " "], trim: true)
      |> MapSet.new()

    Enum.reject(specs, &MapSet.member?(exclusions, &1))
  end

  defp extract_provider(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, _] -> provider
      _ -> "unknown"
    end
  end
end
