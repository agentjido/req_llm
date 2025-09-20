defmodule ReqLLM.Model.Metadata do
  @moduledoc """
  Handles loading, parsing, and processing metadata for AI models.

  This module serves as the central hub for all metadata operations including
  JSON loading, provider parsing, capability extraction, and data transformations.
  """

  @doc """
  Loads full metadata from JSON files for enhanced model creation.

  Attempts to load complete model metadata from provider files in the
  priv/models_dev directory for the given model specification.

  ## Parameters

  - `model_spec` - Model specification string in "provider:model" format

  ## Returns

  `{:ok, metadata_map}` if metadata is found and valid, `{:error, reason}` otherwise.

  ## Examples

      {:ok, metadata} = ReqLLM.Model.Metadata.load_full_metadata("anthropic:claude-3-sonnet")
      metadata["cost"]
      #=> %{"input" => 3.0, "output" => 15.0}

  """
  @spec load_full_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def load_full_metadata(model_spec) do
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

  @doc """
  Parses a provider string to a valid provider atom.

  Converts hyphenated provider names to underscored atoms and validates
  against the list of supported providers.

  ## Parameters

  - `str` - Provider name string (e.g., "anthropic", "google-vertex")

  ## Returns

  `{:ok, atom}` if provider is valid, `{:error, reason}` otherwise.

  ## Examples

      iex> ReqLLM.Model.Metadata.parse_provider("anthropic")
      {:ok, :anthropic}

      iex> ReqLLM.Model.Metadata.parse_provider("google-vertex") 
      {:ok, :google_vertex}

      iex> ReqLLM.Model.Metadata.parse_provider("unknown")
      {:error, "Unknown provider: unknown"}

  """
  @spec parse_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def parse_provider(str) when is_binary(str) do
    atom_candidate = String.replace(str, "-", "_")

    try do
      atom = String.to_existing_atom(atom_candidate)

      if atom in valid_providers() do
        {:ok, atom}
      else
        {:error, "Unsupported provider: #{str}"}
      end
    rescue
      ArgumentError -> {:error, "Unknown provider: #{str}"}
    end
  end

  defp load_model_from_provider_file(provider_path, specific_model_id) do
    with {:ok, content} <- File.read(provider_path),
         {:ok, %{"models" => models}} <- Jason.decode(content),
         %{} = model_data <- Enum.find(models, &(&1["id"] == specific_model_id)) do
      {:ok, model_data}
    else
      {:error, :enoent} ->
        {:error,
         ReqLLM.Error.validation_error(
           :file_not_found,
           "Provider metadata file not found",
           path: provider_path
         )}

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         ReqLLM.Error.validation_error(
           :invalid_json,
           "Invalid JSON in provider metadata file: #{Exception.message(error)}",
           path: provider_path
         )}

      nil ->
        {:error,
         ReqLLM.Error.validation_error(
           :model_not_found,
           "Model not found in provider file",
           model: specific_model_id,
           path: provider_path
         )}

      _ ->
        {:error,
         ReqLLM.Error.validation_error(
           :metadata_load_failed,
           "Failed to load model metadata",
           model: specific_model_id,
           path: provider_path
         )}
    end
  end

  defp load_individual_model_file(metadata_path) do
    with {:ok, content} <- File.read(metadata_path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      {:error, :enoent} ->
        {:error,
         ReqLLM.Error.validation_error(
           :file_not_found,
           "Model metadata file not found",
           path: metadata_path
         )}

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         ReqLLM.Error.validation_error(
           :invalid_json,
           "Invalid JSON in model metadata file: #{Exception.message(error)}",
           path: metadata_path
         )}
    end
  end

  # Whitelist of safe metadata keys to convert to atoms
  @safe_metadata_keys ~w[
    input output context text image reasoning tool_call temperature
    cache_read cache_write limit modalities capabilities cost
  ]

  @doc """
  Converts string keys in metadata maps to atoms for safe keys only.

  This prevents atom leakage by only converting known safe keys to atoms.
  """
  @spec map_string_keys_to_atoms(map() | nil) :: map() | nil
  def map_string_keys_to_atoms(nil), do: nil

  def map_string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) and key in @safe_metadata_keys ->
        atom_key = String.to_existing_atom(key)
        {atom_key, value}

      {key, value} when is_binary(key) ->
        {key, value}

      {key, value} ->
        {key, value}
    end)
  rescue
    ArgumentError ->
      map
  end

  @doc """
  Builds capabilities map from metadata.
  """
  @spec build_capabilities_from_metadata(map()) :: map()
  def build_capabilities_from_metadata(metadata) do
    %{
      reasoning: Map.get(metadata, "reasoning", false),
      tool_call: Map.get(metadata, "tool_call", false),
      temperature: Map.get(metadata, "temperature", false),
      attachment: Map.get(metadata, "attachment", false)
    }
  end

  @doc """
  Converts modality string values to atoms.
  """
  @spec convert_modality_values(map() | nil) :: map() | nil
  def convert_modality_values(nil), do: nil

  def convert_modality_values(modalities) when is_map(modalities) do
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
  Merges model metadata with defaults for missing fields.
  """
  @spec merge_with_defaults(map() | nil, map()) :: map()
  def merge_with_defaults(nil, defaults), do: defaults
  def merge_with_defaults(existing, defaults), do: Map.merge(defaults, existing)

  @doc """
  Gets the default model for a provider spec.

  Falls back to the first available model if no default is specified.

  ## Parameters

  - `spec` - Provider spec struct with `:default_model` and `:models` fields

  ## Returns

  The default model string, or `nil` if no models are available.

  ## Examples

      iex> spec = %{default_model: "gpt-4", models: %{"gpt-3.5" => %{}, "gpt-4" => %{}}}
      iex> ReqLLM.Model.Metadata.default_model(spec)
      "gpt-4"

      iex> spec = %{default_model: nil, models: %{"model-a" => %{}, "model-b" => %{}}}
      iex> ReqLLM.Model.Metadata.default_model(spec)
      "model-a"

      iex> spec = %{default_model: nil, models: %{}}
      iex> ReqLLM.Model.Metadata.default_model(spec)
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

  @doc """
  Exposes model metadata for a provider and model from the registry.

  This is the canonical way to access model metadata, delegating to the
  provider registry's internal metadata storage.

  ## Parameters

  - `provider_id` - Provider atom identifier (e.g., `:anthropic`)
  - `model_name` - Model name string (e.g., `"claude-3-sonnet"`)

  ## Returns

  `{:ok, metadata_map}` if found, `{:error, reason}` otherwise.

  ## Examples

      {:ok, metadata} = ReqLLM.Model.Metadata.get_model_metadata(:anthropic, "claude-3-sonnet")
      metadata["cost"]
      #=> %{"input" => 3.0, "output" => 15.0}
  """
  @spec get_model_metadata(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_metadata(provider_id, model_name)
      when is_atom(provider_id) and is_binary(model_name) do
    case ReqLLM.Provider.Registry.get_provider_metadata(provider_id) do
      {:ok, provider_metadata} ->
        models =
          Map.get(provider_metadata, :models) ||
            Map.get(provider_metadata, "models") ||
            []

        case Enum.find(models, fn model ->
               (Map.get(model, :id) || Map.get(model, "id")) == model_name
             end) do
          nil -> {:error, :model_not_found}
          model_metadata -> {:ok, model_metadata}
        end

      {:error, _reason} ->
        {:error, :model_not_found}
    end
  end

  # Delegate to the generated module for valid providers
  # This list is auto-generated by the model sync task to stay in sync with models.dev
  defp valid_providers do
    ReqLLM.Provider.Generated.ValidProviders.list()
  rescue
    UndefinedFunctionError ->
      # Fallback if generated module doesn't exist yet
      # This can happen on first compile before running the sync task
      IO.warn(
        "Generated ValidProviders module not found. Run 'mix req_llm.model_sync' to generate it."
      )

      []
  end
end
