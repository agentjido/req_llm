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
  - `REQ_LLM_SAMPLE` - Number of models to sample per provider
  - `REQ_LLM_EXCLUDE` - Models to exclude (space or comma separated)
  - `REQ_LLM_INCLUDE_RESPONSES` - Include OpenAI o1/o3 models that require /v1/responses (default: excluded)

  ## Examples

      # Get selected model specs
      specs = ModelMatrix.selected_specs()
      # => ["openai:gpt-4o", "anthropic:claude-3-5-sonnet", ...]

      # Get models for specific provider
      specs = ModelMatrix.models_for_provider(:anthropic)
      # => ["anthropic:claude-3-5-sonnet", "anthropic:claude-3-haiku", ...]
  """

  alias ReqLLM.Provider.Registry

  @default_models Application.compile_env(:req_llm, :test_models, ~w(
    anthropic:claude-3-5-haiku-20241022
    anthropic:claude-3-5-sonnet-20241022
    openai:gpt-4o-mini
    openai:gpt-3.5-turbo
    google:gemini-1.5-flash
    google:gemini-1.5-pro
    groq:gemma2-9b-it
    groq:llama-3.1-8b-instant
    xai:grok-beta
    xai:grok-2-latest
  ))

  @type opts :: [
          env: %{optional(String.t()) => String.t() | nil},
          registry: module()
        ]

  @doc """
  Returns list of model specs to test based on configuration.

  Selection priority:
  1. opts[:env] map or REQ_LLM_MODELS environment variable
  2. Default models from config
  3. Applies sampling if opts[:env]["REQ_LLM_SAMPLE"] or REQ_LLM_SAMPLE is set
  4. Applies exclusions if opts[:env]["REQ_LLM_EXCLUDE"] or REQ_LLM_EXCLUDE is set

  ## Options

    * `:env` - Map of environment variables to use instead of System.get_env
    * `:registry` - Registry module to use (default: ReqLLM.Provider.Registry)

  ## Examples

      # Default models (production usage)
      ModelMatrix.selected_specs()
      # => ["openai:gpt-4o", "openai:gpt-4o-mini", ...]

      # All models with custom env (test usage)
      ModelMatrix.selected_specs(env: %{"REQ_LLM_MODELS" => "all"}, registry: FakeRegistry)
      # => All available model specs from FakeRegistry

      # Pattern-based
      ModelMatrix.selected_specs(env: %{"REQ_LLM_MODELS" => "anthropic:*"})
      # => All Anthropic models
  """
  @spec selected_specs() :: [binary()]
  def selected_specs, do: selected_specs([])

  @spec selected_specs(opts()) :: [binary()]
  def selected_specs(opts) do
    env = Keyword.get(opts, :env, %{})
    registry = Keyword.get(opts, :registry, Registry)

    pattern = get_env_value(env, "REQ_LLM_MODELS")
    sample = get_env_value(env, "REQ_LLM_SAMPLE")
    exclude = get_env_value(env, "REQ_LLM_EXCLUDE")
    include_responses = get_env_value(env, "REQ_LLM_INCLUDE_RESPONSES")

    resolve_base_selection(pattern, registry)
    |> maybe_sample(sample)
    |> maybe_exclude(exclude)
    |> maybe_exclude_responses_only(include_responses)
    |> Enum.sort()
  end

  @doc """
  Returns models for a specific provider.

  Filters selected_specs() to only include models from the given provider.

  ## Examples

      ModelMatrix.models_for_provider(:anthropic)
      # => ["anthropic:claude-3-5-sonnet", ...]

      # With options for testing
      ModelMatrix.models_for_provider(:anthropic, registry: FakeRegistry)
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

  defp resolve_base_selection(pattern, registry) do
    case pattern do
      "all" ->
        all_model_specs(registry)

      nil ->
        default_model_specs()

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
    case String.split(pattern, ":") do
      [provider, "*"] ->
        expand_provider_wildcard(String.to_atom(provider), registry)

      [_provider, _model] ->
        [pattern]

      _ ->
        []
    end
  end

  defp expand_provider_wildcard(provider, registry) do
    case registry.list_models(provider) do
      {:ok, models} -> Enum.map(models, &"#{provider}:#{&1}")
      {:error, _} -> []
    end
  end

  defp all_model_specs(registry) do
    registry.list_providers()
    |> Enum.flat_map(fn provider ->
      case registry.list_models(provider) do
        {:ok, models} -> Enum.map(models, &"#{provider}:#{&1}")
        {:error, _} -> []
      end
    end)
  end

  defp default_model_specs do
    @default_models
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

  defp maybe_exclude_responses_only(specs, include_str) when include_str in ["1", "true"] do
    specs
  end

  defp maybe_exclude_responses_only(specs, _) do
    Enum.reject(specs, &responses_only_model?/1)
  end

  defp responses_only_model?(spec) do
    String.starts_with?(spec, "openai:o1") or
      String.starts_with?(spec, "openai:o3") or
      String.starts_with?(spec, "openai:o4")
  end

  defp extract_provider(spec) do
    case String.split(spec, ":") do
      [provider, _] -> provider
      _ -> "unknown"
    end
  end
end
