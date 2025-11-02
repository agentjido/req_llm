defmodule ReqLLM.ModelMetadataTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias ReqLLM.Model

  @moduletag timeout: 60_000

  # Helper to load all models from the JSON cache
  defp load_all_models do
    priv_dir = Application.app_dir(:req_llm, "priv")
    models_dir = Path.join(priv_dir, "models_dev")

    models_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.flat_map(&load_models_from_file(models_dir, &1))
  end

  defp load_models_from_file(models_dir, filename) do
    provider_filename = String.trim_trailing(filename, ".json")
    # Convert hyphenated filename to underscored atom
    provider_atom = String.replace(provider_filename, "-", "_") |> String.to_atom()
    file_path = Path.join(models_dir, filename)

    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"models" => models}} ->
            Enum.map(models, &{provider_atom, &1})

          {:ok, single_model} ->
            [{provider_atom, single_model}]

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  describe "all models from JSON cache" do
    setup do
      models = load_all_models()
      {:ok, models: models}
    end

    test "all models can be parsed with correct metadata", %{models: models} do
      capture_io(fn ->
        capture_log(fn ->
          {failed_models, _} =
            Enum.reduce(models, {[], 0}, fn {provider_id, model_data}, {failures, count} ->
              model_id = Map.get(model_data, "id")
              model_spec = "#{provider_id}:#{model_id}"

              try do
                case Model.from(model_spec) do
                  {:ok, parsed_model} ->
                    # Validate that all expected fields are properly parsed
                    validate_model_structure(parsed_model, model_data, model_spec)
                    {failures, count + 1}

                  {:error, reason} ->
                    failure = {model_spec, "Failed to parse: #{inspect(reason)}"}
                    {[failure | failures], count + 1}
                end
              rescue
                error ->
                  failure = {model_spec, "Exception: #{Exception.message(error)}"}
                  {[failure | failures], count + 1}
              end
            end)

          if failed_models != [] do
            IO.puts("\n=== FAILED MODELS ===")

            Enum.each(failed_models, fn {spec, reason} ->
              IO.puts("#{spec}: #{reason}")
            end)

            flunk("#{length(failed_models)} models failed to parse correctly")
          end
        end)
      end)
    end

    test "models with metadata have proper field mapping", %{models: models} do
      capture_log(fn ->
        metadata_fields_issues =
          Enum.reduce(models, [], fn {provider_id, model_data}, acc_issues ->
            model_id = Map.get(model_data, "id")
            model_spec = "#{provider_id}:#{model_id}"
            model_type = Map.get(model_data, "type")

            # Skip embedding models - they're handled separately and not loaded into text model registry
            is_embedding = model_type == "embedding" or String.contains?(model_id, "embedding")

            # Skip non-Anthropic Bedrock models - only Anthropic is fully supported with fixtures
            is_unsupported_bedrock =
              provider_id == :amazon_bedrock and
                not String.starts_with?(model_id, [
                  "anthropic.",
                  "us.anthropic.",
                  "global.anthropic."
                ])

            # Skip models not in catalog_allow
            is_allowed = ReqLLM.Catalog.allowed_spec?(provider_id, model_id)

            if is_embedding or is_unsupported_bedrock or not is_allowed do
              acc_issues
            else
              case Model.from(model_spec) do
                {:ok, parsed_model} ->
                  issues = validate_metadata_mapping(parsed_model, model_data, model_spec)
                  acc_issues ++ issues

                {:error, _} ->
                  # Skip parsing errors - they're covered by the previous test
                  acc_issues
              end
            end
          end)

        if metadata_fields_issues != [] do
          IO.puts("\n=== METADATA MAPPING ISSUES ===")

          Enum.each(metadata_fields_issues, fn {spec, issue} ->
            IO.puts("#{spec}: #{issue}")
          end)

          flunk("#{length(metadata_fields_issues)} models have metadata mapping issues")
        end
      end)
    end
  end

  # Validate the basic structure of a parsed model
  defp validate_model_structure(parsed_model, model_data, model_spec) do
    if !Model.valid?(parsed_model) do
      throw({model_spec, "Invalid model structure"})
    end

    provider_str = Map.get(model_data, "provider", "unknown")
    # Convert hyphenated provider names to underscored atoms, matching the Model module logic
    expected_provider = String.replace(provider_str, "-", "_") |> String.to_atom()
    expected_model_id = Map.get(model_data, "id")

    if parsed_model.provider != expected_provider do
      throw(
        {model_spec,
         "Provider mismatch: expected #{expected_provider}, got #{parsed_model.provider}"}
      )
    end

    if parsed_model.model != expected_model_id do
      throw(
        {model_spec,
         "Model ID mismatch: expected #{expected_model_id}, got #{parsed_model.model}"}
      )
    end
  end

  # Validate that metadata fields are properly mapped
  defp validate_metadata_mapping(parsed_model, model_data, model_spec) do
    []
    |> then(fn issues ->
      # Check cost mapping
      if cost_data = Map.get(model_data, "cost") do
        validate_cost_field(parsed_model.cost, cost_data, model_spec, issues)
      else
        issues
      end
    end)
    |> then(fn issues ->
      # Check limit mapping
      if limit_data = Map.get(model_data, "limit") do
        validate_limit_field(parsed_model.limit, limit_data, model_spec, issues)
      else
        issues
      end
    end)
    |> then(fn issues ->
      # Check modalities mapping
      if modalities_data = Map.get(model_data, "modalities") do
        validate_modalities_field(parsed_model.modalities, modalities_data, model_spec, issues)
      else
        issues
      end
    end)
    |> then(fn issues ->
      # Check capabilities mapping
      validate_capabilities_field(parsed_model.capabilities, model_data, model_spec, issues)
    end)
  end

  defp validate_cost_field(nil, _expected, model_spec, issues) do
    [{model_spec, "Cost data missing from parsed model"} | issues]
  end

  defp validate_cost_field(parsed_cost, expected_cost, model_spec, issues) do
    required_keys = ["input", "output"]
    optional_keys = ["cache_read", "cache_write"]

    # Check required keys
    issues =
      Enum.reduce(required_keys, issues, fn key, acc ->
        expected_value = Map.get(expected_cost, key)
        parsed_value = Map.get(parsed_cost, String.to_existing_atom(key))

        cond do
          expected_value != nil and parsed_value == nil ->
            [{model_spec, "Missing cost.#{key} in parsed model"} | acc]

          expected_value != nil and parsed_value != expected_value ->
            [
              {model_spec,
               "Cost.#{key} mismatch: expected #{expected_value}, got #{parsed_value}"}
              | acc
            ]

          true ->
            acc
        end
      end)

    # Check optional keys - only compare when both are present
    Enum.reduce(optional_keys, issues, fn key, acc ->
      expected_value = Map.get(expected_cost, key)
      parsed_value = Map.get(parsed_cost, String.to_existing_atom(key))

      if expected_value != nil and parsed_value != nil and parsed_value != expected_value do
        [
          {model_spec, "Cost.#{key} mismatch: expected #{expected_value}, got #{parsed_value}"}
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp validate_limit_field(nil, _expected, model_spec, issues) do
    [{model_spec, "Limit data missing from parsed model"} | issues]
  end

  defp validate_limit_field(parsed_limit, expected_limit, model_spec, issues) do
    required_keys = ["context"]
    optional_keys = ["output"]

    # Check required keys
    issues =
      Enum.reduce(required_keys, issues, fn key, acc ->
        expected_value = Map.get(expected_limit, key)
        parsed_value = Map.get(parsed_limit, String.to_existing_atom(key))

        cond do
          expected_value != nil and parsed_value == nil ->
            [{model_spec, "Missing limit.#{key} in parsed model"} | acc]

          expected_value != nil and parsed_value != expected_value ->
            [
              {model_spec,
               "Limit.#{key} mismatch: expected #{expected_value}, got #{parsed_value}"}
              | acc
            ]

          true ->
            acc
        end
      end)

    # Check optional keys - only compare when both are present
    Enum.reduce(optional_keys, issues, fn key, acc ->
      expected_value = Map.get(expected_limit, key)
      parsed_value = Map.get(parsed_limit, String.to_existing_atom(key))

      if expected_value != nil and parsed_value != nil and parsed_value != expected_value do
        [
          {model_spec, "Limit.#{key} mismatch: expected #{expected_value}, got #{parsed_value}"}
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp validate_modalities_field(nil, _expected, model_spec, issues) do
    [{model_spec, "Modalities data missing from parsed model"} | issues]
  end

  defp validate_modalities_field(parsed_modalities, expected_modalities, model_spec, issues) do
    required_keys = ["input", "output"]

    Enum.reduce(required_keys, issues, fn key, acc ->
      try do
        expected_values = Map.get(expected_modalities, key, [])
        parsed_values = Map.get(parsed_modalities, String.to_existing_atom(key), [])

        # Convert strings to atoms for comparison
        expected_atoms = Enum.map(expected_values, &String.to_atom/1)

        if MapSet.new(expected_atoms) == MapSet.new(parsed_values) do
          acc
        else
          [
            {model_spec,
             "Modalities.#{key} mismatch: expected #{inspect(expected_atoms)}, got #{inspect(parsed_values)}"}
            | acc
          ]
        end
      rescue
        ArgumentError ->
          [{model_spec, "Invalid modalities.#{key} - contains unknown atoms"} | acc]
      end
    end)
  end

  defp validate_capabilities_field(nil, _model_data, model_spec, issues) do
    [{model_spec, "Capabilities data missing from parsed model"} | issues]
  end

  defp validate_capabilities_field(parsed_capabilities, model_data, model_spec, issues) do
    capability_mappings = [
      {"reasoning", :reasoning},
      {"tool_call", :tool_call},
      {"temperature", :temperature},
      {"attachment", :attachment}
    ]

    # Debug output for problematic models
    if String.contains?(model_spec, "llama3-2-1b") or String.contains?(model_spec, "llama3-2-3b") do
      IO.puts("\n=== DEBUG: #{model_spec} ===")
      IO.puts("model_data: #{inspect(model_data, pretty: true)}")
      IO.puts("parsed_capabilities: #{inspect(parsed_capabilities, pretty: true)}")
    end

    # Only assert when JSON advertises capability as true
    Enum.reduce(capability_mappings, issues, fn {json_key, struct_key}, acc ->
      expected_value = Map.get(model_data, json_key, false)
      parsed_value = Map.get(parsed_capabilities, struct_key, false)

      if expected_value == true and parsed_value != true do
        [{model_spec, "Capability #{struct_key} missing (expected true)"} | acc]
      else
        acc
      end
    end)
  end
end
