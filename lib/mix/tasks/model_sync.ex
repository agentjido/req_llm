defmodule Mix.Tasks.ReqLlm.ModelSync do
  @shortdoc "Synchronize model data from models.dev API"

  @moduledoc """
  Synchronize AI model catalog and pricing data from the models.dev API.

  This task fetches comprehensive model information including capabilities, pricing,
  and provider details from models.dev API and generates local JSON files for use
  by the ReqLLM library. Essential for keeping model data up-to-date.

  ## Usage

      mix req_llm.model_sync [options]

  ## Options

      --verbose               Show detailed progress and statistics during sync

  ## Examples

      # Basic synchronization (quiet mode)
      mix req_llm.model_sync

      # Detailed synchronization with progress information
      mix req_llm.model_sync --verbose

  ## What This Task Does

  1. **Fetches Model Data**: Downloads complete model catalog from models.dev API
  2. **Processes Providers**: Extracts and organizes data by AI provider
  3. **Merges Local Patches**: Applies any local model customizations
  4. **Generates Files**: Creates JSON files for each provider
  5. **Updates Code**: Regenerates ValidProviders module with available providers

  ## Output Structure

  After running, the following files are created/updated:

      priv/models_dev/
      ├── anthropic.json         # Anthropic models (Claude, etc.)
      ├── openai.json            # OpenAI models (GPT-4, GPT-3.5, etc.)
      ├── google.json            # Google models (Gemini, etc.)
      ├── groq.json              # Groq models
      ├── xai.json               # xAI models (Grok, etc.)
      ├── openrouter.json        # OpenRouter proxy models
      └── ...                    # Additional providers as available

      lib/req_llm/provider/generated/
      └── valid_providers.ex     # Generated list of valid provider atoms

  ## Data Sources

  **Primary**: models.dev API (https://models.dev/api.json)
  - Official model specifications
  - Current pricing information  
  - Provider configuration details
  - Model capabilities and limits

  **Local Patches**: priv/models_local/*.json (optional)
  - Custom model definitions
  - Provider-specific overrides
  - Local testing models
  - Model exclusions

  ## Provider Information Included

  For each provider, the following data is synchronized:

      - Provider ID and display name
      - Base API URL and authentication requirements
      - Environment variable names for API keys
      - Complete model catalog with IDs and names
      - Pricing information (input/output token costs)
      - Model capabilities (context length, supported features)
      - Provider-specific configuration requirements

  ## Local Customization

  You can add local model definitions by creating JSON files in:

      priv/models_local/
      ├── custom_provider.json
      └── model_overrides.json

  Local patch files should follow this structure:

      {
        "provider": {
          "id": "custom_provider",
          "name": "My Custom Provider"
        },
        "models": [
          {
            "id": "custom-model-1",
            "name": "Custom Model 1",
            "pricing": {
              "input": 0.001,
              "output": 0.002
            }
          }
        ]
      }

  To exclude models from a provider:

      {
        "provider": {
          "id": "xai"
        },
        "exclude": [
          "grok-vision-beta"
        ]
      }

  ## When to Run This Task

  - **After library updates**: When ReqLLM is updated to ensure model compatibility
  - **New provider support**: When providers add new models or change pricing
  - **Regular maintenance**: Weekly or monthly to keep pricing current
  - **Before production**: Always sync before deploying to production

  ## Error Handling

  Common issues and solutions:

  - **Network errors**: Check internet connection and models.dev API status
  - **API changes**: models.dev API structure may change, requiring code updates  
  - **File permissions**: Ensure write access to priv/ and lib/ directories
  - **Invalid patches**: Local patch files must follow valid JSON structure

  ## Integration with ReqLLM

  The synchronized data is automatically used by:

  - Provider validation during model selection
  - Cost estimation for usage tracking
  - Model capability detection
  - Provider configuration and authentication setup

  ## Development Notes

  - Task runs in :dev environment by default
  - Generates Elixir modules that are compiled into the application
  - Provider IDs are normalized (kebab-case to snake_case atoms)
  - Model data is pruned to remove unnecessary fields for efficiency
  """

  use Mix.Task

  require Logger

  @preferred_cli_env ["req_llm.model_sync": :dev]

  # API endpoint
  @models_dev_api "https://models.dev/api.json"

  # Directory structure
  @providers_dir "priv/models_dev"
  @patches_dir "priv/models_local"

  # Fields we don't need from models.dev that should be filtered out
  @unused_fields ~w[
    npm
    packageName
    license
    repository
    bugs
    homepage
    engines
    keywords
    exports
    dependencies
  ]

  @spec run([String.t()]) :: :ok
  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:req_llm)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          verbose: :boolean
        ],
        aliases: [
          v: :verbose
        ]
      )

    verbose? = Keyword.get(opts, :verbose, false)

    if verbose?, do: IO.puts("Starting model synchronization...")

    case execute_sync(verbose?) do
      :ok ->
        IO.puts("✓ Updated catalog manifest (will trigger recompilation)")
        IO.puts("Model synchronization completed successfully")
        :ok

      {:error, reason} ->
        IO.puts("Synchronization failed: #{reason}")
        System.halt(1)
    end
  end

  @doc """
  Execute the synchronization process.
  """
  @spec execute_sync(boolean()) :: :ok | {:error, term()}
  def execute_sync(verbose? \\ false) do
    File.mkdir_p!(@providers_dir)

    with {:ok, models_data} <- fetch_models_dev_data(verbose?) do
      merged_data = merge_local_patches(models_data, verbose?)
      save_provider_files(merged_data, verbose?)
      write_manifest(verbose?)
    end
  end

  defp fetch_models_dev_data(verbose?) do
    if verbose?, do: IO.puts("Fetching models.dev catalog...")

    case Req.get(@models_dev_api) do
      {:ok, %{status: 200, body: data}} ->
        if verbose? do
          provider_count = map_size(data)
          model_count = count_total_models(data)

          IO.puts(
            "Downloaded models.dev data: #{provider_count} providers, #{model_count} models"
          )
        end

        {:ok, data}

      {:ok, %{status: status}} ->
        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "models.dev API returned status #{status}",
           status: status
         )}

      {:error, reason} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Failed to fetch models.dev data: #{inspect(reason)}"
         )}
    end
  end

  defp save_provider_files(models_data, verbose?) do
    models_data
    |> Enum.each(fn {provider_id, provider_data} ->
      normalized_id = normalize_provider_id(provider_id)
      models = process_provider_models(provider_data["models"] || %{}, normalized_id)

      if not Enum.empty?(models) do
        provider_file = Path.join(@providers_dir, "#{normalized_id}.json")
        fallback_config = get_provider_config(normalized_id)

        existing_provider = provider_data["provider"] || %{}

        provider_json = %{
          "provider" => %{
            "id" => normalized_id,
            "name" =>
              existing_provider["name"] || provider_data["name"] ||
                format_provider_name(normalized_id),
            "base_url" =>
              existing_provider["base_url"] || provider_data["base_url"] ||
                fallback_config["base_url"],
            "env" =>
              existing_provider["env"] || provider_data["env"] || fallback_config["env"] || [],
            "doc" =>
              existing_provider["doc"] || provider_data["description"] || "AI model provider"
          },
          "models" => prune_model_fields(models)
        }

        File.write!(provider_file, Jason.encode!(provider_json, pretty: true))

        if verbose? do
          IO.puts("  Saved #{length(models)} models for #{normalized_id}")
        end
      end
    end)

    # Generate ValidProviders module
    provider_ids =
      models_data
      |> Enum.filter(fn {_provider_id, provider_data} ->
        models = provider_data["models"] || %{}
        not Enum.empty?(models)
      end)
      |> Enum.map(fn {provider_id, _provider_data} -> normalize_provider_id(provider_id) end)

    generate_valid_providers_module(provider_ids, verbose?)

    :ok
  end

  defp process_provider_models(models_map, provider_id) do
    models_map
    |> Enum.map(fn {_model_id, model_data} ->
      Map.merge(model_data, %{
        "provider" => provider_id,
        "provider_model_id" => model_data["id"]
      })
    end)
  end

  defp prune_model_fields(models) do
    models
    |> Enum.map(fn model ->
      Enum.reduce(@unused_fields, model, fn field, acc ->
        Map.delete(acc, field)
      end)
    end)
  end

  defp count_total_models(providers_data) do
    providers_data
    |> Enum.map(fn {_, provider} -> map_size(provider["models"] || %{}) end)
    |> Enum.sum()
  end

  defp normalize_provider_id(provider_id) do
    String.replace(provider_id, "-", "_")
  end

  defp format_provider_name(provider_id) do
    provider_id
    |> String.split(["-", "_"])
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Provider-specific fallback configuration
  #
  # These configurations are used as fallbacks when:
  # 1. The models.dev API doesn't provide complete provider metadata
  # 2. Local patch files don't override these values
  #
  # Priority order (highest to lowest):
  # 1. Local patch file (priv/models_local/<provider>_patch.json)
  # 2. models.dev API data
  # 3. Hardcoded fallback config (below)
  #
  # This means you can override any provider config by creating a patch file.
  defp get_provider_config("openai") do
    %{
      "base_url" => "https://api.openai.com/v1",
      "env" => ["OPENAI_API_KEY"]
    }
  end

  defp get_provider_config("anthropic") do
    %{
      "base_url" => "https://api.anthropic.com",
      "env" => ["ANTHROPIC_API_KEY"]
    }
  end

  defp get_provider_config("openrouter") do
    %{
      "base_url" => "https://openrouter.ai/api/v1",
      "env" => ["OPENROUTER_API_KEY"]
    }
  end

  defp get_provider_config("google") do
    %{
      "base_url" => "https://generativelanguage.googleapis.com/v1",
      "env" => ["GOOGLE_API_KEY"]
    }
  end

  defp get_provider_config("cloudflare") do
    %{
      "base_url" => "https://api.cloudflare.com/client/v4/accounts",
      "env" => ["CLOUDFLARE_API_KEY"]
    }
  end

  defp get_provider_config(_provider_id) do
    %{}
  end

  defp merge_local_patches(models_data, verbose?) do
    if File.exists?(@patches_dir) do
      patch_files = Path.wildcard(Path.join(@patches_dir, "*.json"))

      if verbose? && !Enum.empty?(patch_files) do
        IO.puts("Found #{length(patch_files)} patch files to merge")
      end

      Enum.reduce(patch_files, models_data, fn patch_file, acc ->
        case load_patch_file(patch_file, verbose?) do
          {:ok, provider_data, patch_payload} ->
            merge_patch_data(acc, provider_data, patch_payload, verbose?)

          {:error, _reason} ->
            acc
        end
      end)
    else
      if verbose? do
        IO.puts("No patches directory found (#{@patches_dir})")
      end

      models_data
    end
  end

  defp load_patch_file(patch_file, verbose?) do
    case File.read(patch_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"provider" => provider_data, "models" => patch_models}} ->
            if verbose? do
              IO.puts(
                "  Loading patch: #{Path.basename(patch_file)} (#{length(patch_models)} models)"
              )
            end

            {:ok, provider_data, {:models, patch_models}}

          {:ok, %{"provider" => provider_data, "exclude" => exclusions}} ->
            if verbose? do
              IO.puts(
                "  Loading exclusions: #{Path.basename(patch_file)} (#{length(exclusions)} models)"
              )
            end

            {:ok, provider_data, {:exclude, exclusions}}

          {:ok, _} ->
            IO.puts("Warning: Invalid patch file structure: #{patch_file}")
            {:error, :invalid_structure}

          {:error, error} ->
            IO.puts("Warning: Failed to parse patch file #{patch_file}: #{inspect(error)}")
            {:error, :json_parse_error}
        end

      {:error, error} ->
        IO.puts("Warning: Failed to read patch file #{patch_file}: #{inspect(error)}")
        {:error, :file_read_error}
    end
  end

  defp merge_patch_data(models_data, provider_data, {:exclude, exclusions}, verbose?) do
    provider_id = normalize_provider_id(provider_data["id"])

    case Map.get(models_data, provider_id) do
      nil ->
        if verbose? do
          IO.puts("    Skipping exclusions for unknown provider: #{provider_id}")
        end

        models_data

      existing_provider_data ->
        existing_models = existing_provider_data["models"] || %{}

        exclusion_set = MapSet.new(exclusions)
        filtered_models = Map.drop(existing_models, MapSet.to_list(exclusion_set))

        if verbose? do
          excluded_count = map_size(existing_models) - map_size(filtered_models)
          IO.puts("    Provider #{provider_id}: excluded #{excluded_count} models")
        end

        updated_provider_data = Map.put(existing_provider_data, "models", filtered_models)
        Map.put(models_data, provider_id, updated_provider_data)
    end
  end

  defp merge_patch_data(models_data, provider_data, {:models, patch_models}, verbose?) do
    provider_id = normalize_provider_id(provider_data["id"])

    case Map.get(models_data, provider_id) do
      nil ->
        patch_models_map =
          patch_models
          |> Map.new(fn model -> {model["id"], model} end)

        provider_config = get_provider_config(provider_id)

        new_provider_data = %{
          "provider" => %{
            "id" => provider_id,
            "name" => provider_data["name"] || format_provider_name(provider_id),
            "doc" => provider_data["doc"] || "AI model provider",
            "base_url" => provider_data["base_url"] || provider_config["base_url"],
            "env" => provider_data["env"] || provider_config["env"] || []
          },
          "models" => patch_models_map
        }

        if verbose? do
          IO.puts(
            "    Provider #{provider_id}: created net-new provider with #{map_size(patch_models_map)} models"
          )
        end

        Map.put(models_data, provider_id, new_provider_data)

      existing_provider_data ->
        existing_models = existing_provider_data["models"] || %{}

        patch_models_map =
          patch_models
          |> Map.new(fn model -> {model["id"], model} end)

        merged_models =
          Map.merge(existing_models, patch_models_map, fn _key, existing, patch ->
            Map.merge(existing, patch)
          end)

        if verbose? do
          added_count =
            map_size(patch_models_map) -
              map_size(Map.take(existing_models, Map.keys(patch_models_map)))

          updated_count = map_size(patch_models_map) - added_count

          IO.puts(
            "    Provider #{provider_id}: added #{added_count}, updated #{updated_count} models"
          )
        end

        existing_provider_config = existing_provider_data["provider"] || %{}
        merged_provider_config = Map.merge(existing_provider_config, provider_data)

        updated_provider_data =
          existing_provider_data
          |> Map.put("models", merged_models)
          |> Map.put("provider", merged_provider_config)

        Map.put(models_data, provider_id, updated_provider_data)
    end
  end

  defp generate_valid_providers_module(provider_ids, verbose?) do
    if verbose? do
      IO.puts("Generating ValidProviders module with #{length(provider_ids)} providers")
    end

    provider_atoms =
      provider_ids
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&String.to_atom/1)

    module_code =
      """
      defmodule ReqLLM.Provider.Generated.ValidProviders do
        @moduledoc false

        @doc \"\"\"
        Returns the list of valid provider atoms.
        
        This module is auto-generated by the model sync task.
        Do not edit manually.
        \"\"\"
        @providers #{inspect(provider_atoms, limit: :infinity)}
        
        @spec list() :: [atom()]
        def list, do: @providers
        
        @spec member?(atom()) :: boolean()
        def member?(atom), do: atom in @providers
      end
      """

    # Ensure directory exists
    generated_dir = "lib/req_llm/provider/generated"
    File.mkdir_p!(generated_dir)

    # Write the generated module
    module_path = Path.join(generated_dir, "valid_providers.ex")
    File.write!(module_path, module_code)

    # Format the generated file
    Code.format_file!(module_path) |> then(&File.write!(module_path, &1))

    if verbose? do
      IO.puts("  Generated #{module_path}")
    end
  end

  defp write_manifest(verbose?) do
    provider_files =
      Path.wildcard(Path.join(@providers_dir, "*.json"))
      |> Enum.sort()

    concatenated_content =
      provider_files
      |> Enum.map_join(&File.read!/1)

    hash =
      :crypto.hash(:sha256, concatenated_content)
      |> Base.encode16(case: :lower)

    manifest = %{
      "files" => provider_files,
      "hash" => hash,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    manifest_path = Path.join(@providers_dir, ".catalog_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    if verbose? do
      IO.puts(
        "  Generated manifest with #{length(provider_files)} files (hash: #{String.slice(hash, 0..7)})"
      )
    end

    :ok
  end
end
