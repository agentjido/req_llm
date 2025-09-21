defmodule ReqLLM.Model.Metadata do
  @moduledoc """
  Handles loading metadata from JSON files for AI models.

  This module is responsible for loading model metadata from provider files 
  in the priv/models_dev directory. For metadata processing and validation,
  see `ReqLLM.Metadata`.
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
    {:ok, provider_metadata} = ReqLLM.Provider.Registry.get_provider_metadata(provider_id)

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
  end
end
