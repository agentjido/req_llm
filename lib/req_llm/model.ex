defmodule ReqLLM.Model do
  @moduledoc """
  Represents an AI model configuration for ReqLLM.

  This module provides a simplified model structure focused on essential
  fields needed for AI interactions: provider information, model name,
  and runtime parameters like temperature and token limits.

  ## Examples

      # Create a model with 3-tuple format (preferred)
      {:ok, model} = ReqLLM.Model.from({:anthropic, "claude-3-5-sonnet", temperature: 0.7})

      # Create a model with legacy 2-tuple format
      {:ok, model} = ReqLLM.Model.from({:anthropic, model: "claude-3-5-sonnet", temperature: 0.7})

      # Create a model from string specification
      {:ok, model} = ReqLLM.Model.from("anthropic:claude-3-5-sonnet")

      # Create a model directly
      model = ReqLLM.Model.new(:anthropic, "claude-3-sonnet", temperature: 0.5, max_tokens: 1000)

  """

  use TypedStruct

  @type modality :: :text | :audio | :image | :video | :pdf
  @type cost :: %{input: float(), output: float()}
  @type limit :: %{context: non_neg_integer(), output: non_neg_integer()}
  @type capabilities :: %{
          reasoning: boolean(),
          tool_call: boolean(),
          temperature: boolean(),
          attachment: boolean()
        }

  @derive {Jason.Encoder, only: [:provider, :model, :max_tokens, :max_retries]}
  typedstruct do
    @typedoc "An AI model configuration"

    # Required runtime fields
    field(:provider, atom(), enforce: true)
    field(:model, String.t(), enforce: true)
    field(:max_tokens, non_neg_integer() | nil)
    field(:max_retries, non_neg_integer() | nil, default: 3)

    # Optional metadata fields
    field(:limit, limit() | nil)
    field(:modalities, %{input: [modality()], output: [modality()]} | nil)
    field(:capabilities, capabilities() | nil)
    field(:cost, cost() | nil)
  end

  @doc """
  Creates a new model with the specified provider and model name.

  ## Parameters

  - `provider` - The provider atom (e.g., `:anthropic`)
  - `model` - The model name string (e.g., `"gpt-4"`, `"claude-3-sonnet"`)
  - `opts` - Optional keyword list of parameters

  ## Options

  - `:max_tokens` - Maximum tokens the model can generate (defaults to model's output limit)
  - `:max_retries` - Maximum retry attempts (default: 3)
  - `:limit` - Token limits map with `:context` and `:output` keys
  - `:modalities` - Input/output modalities map with lists of supported types
  - `:capabilities` - Model capabilities like `:reasoning`, `:tool_call`, `:temperature`, `:attachment`
  - `:cost` - Pricing information with `:input` and `:output` cost per 1K tokens

  ## Examples

      iex> ReqLLM.Model.new(:anthropic, "claude-3-5-sonnet")
      %ReqLLM.Model{provider: :anthropic, model: "claude-3-5-sonnet", max_tokens: nil, max_retries: 3}

      iex> ReqLLM.Model.new(:anthropic, "claude-3-sonnet", max_tokens: 1000)
      %ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet", max_tokens: 1000, max_retries: 3}

  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(provider, model, opts \\ []) when is_atom(provider) and is_binary(model) do
    limit = Keyword.get(opts, :limit)
    default_max_tokens = if limit, do: Map.get(limit, :output)

    %__MODULE__{
      provider: provider,
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens),
      max_retries: Keyword.get(opts, :max_retries, 3),
      limit: limit,
      modalities: Keyword.get(opts, :modalities),
      capabilities: Keyword.get(opts, :capabilities),
      cost: Keyword.get(opts, :cost)
    }
  end

  @doc """
  Creates a model from various input formats.

  Supports:
  - Existing Model struct (returned as-is)
  - 3-tuple format: `{provider, model, opts}` where provider is atom, model is string, opts is keyword list
  - 2-tuple format (legacy): `{provider, opts}` where provider is atom and opts is keyword list with `:model` key
  - String format: `"provider:model"` (e.g., `"anthropic:claude-3-5-sonnet"`)

  ## Examples

      # From existing struct
      {:ok, model} = ReqLLM.Model.from(%ReqLLM.Model{provider: :anthropic, model: "claude-3-5-sonnet"})

      # From 3-tuple format (preferred)
      {:ok, model} = ReqLLM.Model.from({:anthropic, "claude-3-5-sonnet", max_tokens: 1000})

      # From 2-tuple format (legacy support)
      {:ok, model} = ReqLLM.Model.from({:anthropic, model: "claude-3-5-sonnet", max_tokens: 1000,
                                       capabilities: %{tool_call: true}})

      # From string specification
      {:ok, model} = ReqLLM.Model.from("anthropic:claude-3-sonnet")

  """
  @spec from(t() | {atom(), String.t(), keyword()} | {atom(), keyword()} | String.t()) ::
          {:ok, t()} | {:error, term()}
  def from(%__MODULE__{} = model), do: {:ok, model}

  # New 3-tuple format: {provider, model, opts}
  def from({provider, model, opts})
      when is_atom(provider) and is_binary(model) and is_list(opts) do
    {:ok, new(provider, model, opts)}
  end

  # Legacy 2-tuple format: {provider, opts} with model in opts
  def from({provider, opts}) when is_atom(provider) and is_list(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        {:error,
         ReqLLM.Error.validation_error(:missing_model, "model is required in options",
           provider: provider
         )}

      model_name when is_binary(model_name) ->
        {:ok, new(provider, model_name, opts)}

      _ ->
        {:error,
         ReqLLM.Error.validation_error(:invalid_model_type, "model must be a string",
           model: Keyword.get(opts, :model)
         )}
    end
  end

  @dialyzer {:nowarn_function, from: 1}
  def from(provider_model_string) when is_binary(provider_model_string) do
    case String.split(provider_model_string, ":", parts: 2) do
      [provider_str, model_name] when provider_str != "" and model_name != "" ->
        case parse_provider(provider_str) do
          {:ok, provider} ->
            # Try to get metadata from provider registry, fallback to basic model
            case ReqLLM.Provider.Registry.get_model(provider, model_name) do
              {:ok, _} = result ->
                result

              {:error, _} ->
                # Fallback to creating basic model without metadata
                {:ok, new(provider, model_name)}
            end

          {:error, reason} ->
            {:error,
             ReqLLM.Error.validation_error(
               :invalid_provider,
               reason,
               provider: provider_str
             )}
        end

      _ ->
        {:error,
         ReqLLM.Error.validation_error(
           :invalid_model_spec,
           "Invalid model specification. Expected format: 'provider:model'",
           spec: provider_model_string
         )}
    end
  end

  def from(input) do
    {:error,
     ReqLLM.Error.validation_error(:invalid_model_spec, "Invalid model specification",
       input: input
     )}
  end

  @doc """
  Creates a model from input, raising an exception on error.

  ## Examples

      iex> model = ReqLLM.Model.from!("anthropic:claude-3-haiku-20240307")
      iex> {model.provider, model.model, model.max_tokens}
      {:anthropic, "claude-3-haiku-20240307", 4096}

  """
  @spec from!(t() | {atom(), String.t(), keyword()} | {atom(), keyword()} | String.t()) :: t()
  def from!(input) do
    case from(input) do
      {:ok, model} -> model
      {:error, error} -> raise error
    end
  end

  @doc """
  Validates that a model struct has required fields.

  ## Examples

      iex> model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-5-sonnet", max_tokens: 4096, max_retries: 3}
      iex> ReqLLM.Model.valid?(model)
      true

      iex> ReqLLM.Model.valid?(%{provider: :anthropic, model: "claude-3-5-sonnet"})
      false

  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{provider: provider, model: model, max_retries: max_retries})
      when is_atom(provider) and is_binary(model) and model != "" and is_integer(max_retries) and
             max_retries >= 0 do
    true
  end

  def valid?(_), do: false

  @doc """
  Returns a model with sensible defaults for missing metadata fields.

  This helper fills in common defaults for models that don't have complete metadata.

  ## Examples

      iex> model = ReqLLM.Model.new(:anthropic, "claude-3-5-sonnet")
      iex> ReqLLM.Model.with_defaults(model).capabilities
      %{reasoning: false, tool_call: false, temperature: true, attachment: false}

  """
  @spec with_defaults(t()) :: t()
  def with_defaults(%__MODULE__{} = model) do
    default_limit = %{context: 128_000, output: 4_096}
    default_modalities = %{input: [:text], output: [:text]}

    default_capabilities = %{
      reasoning: false,
      tool_call: false,
      temperature: true,
      attachment: false
    }

    %{
      model
      | limit: merge_with_defaults(model.limit, default_limit),
        modalities: merge_with_defaults(model.modalities, default_modalities),
        capabilities: merge_with_defaults(model.capabilities, default_capabilities)
    }
  end

  @doc """
  Loads a model with full metadata from the models_dev directory.

  This is useful for capability verification and other scenarios requiring
  detailed model information beyond what's needed for API calls.

  ## Examples

      {:ok, model_with_metadata} = ReqLLM.Model.with_metadata("anthropic:claude-3-sonnet")
      model_with_metadata.cost
      #=> %{"input" => 3.0, "output" => 15.0, ...}

  """
  @spec with_metadata(String.t()) :: {:ok, t()} | {:error, String.t()}
  def with_metadata(model_spec) when is_binary(model_spec) do
    with {:ok, base_model} <- from(model_spec),
         {:ok, full_metadata} <- load_full_metadata(model_spec) do
      enhanced_model = %{
        base_model
        | limit: get_in(full_metadata, ["limit"]) |> map_string_keys_to_atoms(),
          modalities:
            get_in(full_metadata, ["modalities"])
            |> map_string_keys_to_atoms()
            |> convert_modality_values(),
          capabilities: build_capabilities_from_metadata(full_metadata),
          cost: get_in(full_metadata, ["cost"]) |> map_string_keys_to_atoms()
      }

      {:ok, enhanced_model}
    end
  end

  defp merge_with_defaults(nil, defaults), do: defaults
  defp merge_with_defaults(existing, defaults), do: Map.merge(defaults, existing)

  # Define a comprehensive list of valid provider atoms based on available metadata
  # These atoms are safe because they're defined at compile time, not from user input
  # Note: Not all providers are fully implemented - some are metadata-only
  @valid_providers [
    :alibaba,
    :alibaba_cn,
    :amazon_bedrock,
    :anthropic,
    :azure,
    :baseten,
    :cerebras,
    :chutes,
    :cloudflare_workers_ai,
    :deepinfra,
    :deepseek,
    :fastrouter,
    :fireworks_ai,
    :github_copilot,
    :github_models,
    :google,
    :google_vertex,
    :google_vertex_anthropic,
    :groq,
    :huggingface,
    :inception,
    :inference,
    :llama,
    :lmstudio,
    :mistral,
    :modelscope,
    :moonshotai,
    :moonshotai_cn,
    :morph,
    :nvidia,
    :openai,
    :opencode,
    :openrouter,
    :requesty,
    :submodel,
    :synthetic,
    :togetherai,
    :upstage,
    :v0,
    :venice,
    :vercel,
    :wandb,
    :xai,
    :zai,
    :zai_coding_plan,
    :zhipuai
  ]

  defp parse_provider(str) when is_binary(str) do
    # Convert hyphenated provider names to underscored atoms
    atom_candidate = String.replace(str, "-", "_")

    # Only use String.to_existing_atom to prevent atom table leaks
    try do
      atom = String.to_existing_atom(atom_candidate)

      if atom in @valid_providers do
        {:ok, atom}
      else
        {:error, "Unsupported provider: #{str}"}
      end
    rescue
      ArgumentError -> {:error, "Unknown provider: #{str}"}
    end
  end

  # Load full metadata from JSON files for enhanced model creation
  defp load_full_metadata(model_spec) do
    priv_dir = Application.app_dir(:req_llm, "priv")

    case String.split(model_spec, ":", parts: 2) do
      [provider_id, specific_model_id] ->
        provider_path = Path.join([priv_dir, "models_dev", "#{provider_id}.json"])
        load_model_from_provider_file(provider_path, specific_model_id)

      [single_model_id] ->
        metadata_path = Path.join([priv_dir, "models_dev", "#{single_model_id}.json"])
        load_individual_model_file(metadata_path)
    end
  end

  defp load_model_from_provider_file(provider_path, specific_model_id) do
    with {:ok, content} <- File.read(provider_path),
         {:ok, %{"models" => models}} <- Jason.decode(content),
         %{} = model_data <- Enum.find(models, &(&1["id"] == specific_model_id)) do
      {:ok, model_data}
    else
      {:error, :enoent} ->
        {:error, "Provider metadata not found: #{provider_path}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid JSON in #{provider_path}: #{Exception.message(error)}"}

      nil ->
        {:error, "Model #{specific_model_id} not found in provider file"}

      _ ->
        {:error, "Failed to load model metadata"}
    end
  end

  defp load_individual_model_file(metadata_path) do
    with {:ok, content} <- File.read(metadata_path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      {:error, :enoent} ->
        {:error, "Model metadata not found: #{metadata_path}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid JSON in #{metadata_path}: #{Exception.message(error)}"}
    end
  end

  # Whitelist of safe metadata keys to convert to atoms
  @safe_metadata_keys ~w[
    input output context text image reasoning tool_call temperature
    cache_read cache_write limit modalities capabilities cost
  ]

  defp map_string_keys_to_atoms(nil), do: nil

  defp map_string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) and key in @safe_metadata_keys ->
        atom_key = String.to_existing_atom(key)
        {atom_key, value}

      {key, value} when is_binary(key) ->
        # Keep unsafe keys as strings to prevent atom leakage
        {key, value}

      {key, value} ->
        {key, value}
    end)
  rescue
    ArgumentError ->
      # If any safe key doesn't exist as an atom, just return the map as-is
      map
  end

  defp build_capabilities_from_metadata(metadata) do
    %{
      reasoning: Map.get(metadata, "reasoning", false),
      tool_call: Map.get(metadata, "tool_call", false),
      temperature: Map.get(metadata, "temperature", false),
      attachment: Map.get(metadata, "attachment", false)
    }
  end

  # Convert modality string values to atoms
  defp convert_modality_values(nil), do: nil

  defp convert_modality_values(modalities) when is_map(modalities) do
    modalities
    |> Map.new(fn
      {:input, values} when is_list(values) ->
        {:input, Enum.map(values, &String.to_atom/1)}

      {:output, values} when is_list(values) ->
        {:output, Enum.map(values, &String.to_atom/1)}

      {key, value} ->
        {key, value}
    end)
  end

  @doc """
  Gets the default model for a provider spec.

  Falls back to the first available model if no default is specified.

  ## Parameters

  - `spec` - Provider spec struct with `:default_model` and `:models` fields

  ## Returns

  The default model string, or `nil` if no models are available.

  ## Examples

      iex> spec = %{default_model: "gpt-4", models: %{"gpt-3.5" => %{}, "gpt-4" => %{}}}
      iex> ReqLLM.Model.default_model(spec)
      "gpt-4"

      iex> spec = %{default_model: nil, models: %{"model-a" => %{}, "model-b" => %{}}}
      iex> ReqLLM.Model.default_model(spec)
      "model-a"

      iex> spec = %{default_model: nil, models: %{}}
      iex> ReqLLM.Model.default_model(spec)
      nil
  """
  @spec default_model(map()) :: binary() | nil
  def default_model(spec) do
    spec.default_model ||
      case Map.keys(spec.models) do
        [first_model | _] -> first_model
        [] -> nil
      end
  end
end
