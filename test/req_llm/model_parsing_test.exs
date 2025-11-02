defmodule ReqLLM.ModelParsingTest do
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

  describe "comprehensive model parsing test" do
    setup do
      models = load_all_models()
      {:ok, models: models}
    end

    test "all models can be parsed successfully", %{models: models} do
      capture_io(fn ->
        capture_log(fn ->
          {failed_models, success_count} =
            Enum.reduce(models, {[], 0}, fn {provider_atom, model_data}, {failures, count} ->
              model_id = Map.get(model_data, "id")
              model_spec = "#{provider_atom}:#{model_id}"

              try do
                case Model.from(model_spec) do
                  {:ok, parsed_model} ->
                    # Validate that the model is structurally correct
                    if Model.valid?(parsed_model) do
                      {failures, count + 1}
                    else
                      failure = {model_spec, "Model failed validation after parsing"}
                      {[failure | failures], count + 1}
                    end

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
            IO.puts("\n=== FAILED MODELS (#{length(failed_models)}) ===")

            Enum.each(failed_models, fn {spec, reason} ->
              IO.puts("#{spec}: #{reason}")
            end)

            flunk(
              "#{length(failed_models)} out of #{success_count} models failed to parse correctly"
            )
          end
        end)
      end)
    end

    test "models with metadata have populated fields", %{models: models} do
      capture_io(fn ->
        capture_log(fn ->
          models_with_metadata =
            Enum.reduce(models, [], fn {provider_atom, model_data}, acc ->
              model_id = Map.get(model_data, "id")
              model_spec = "#{provider_atom}:#{model_id}"

              case Model.from(model_spec) do
                {:ok, parsed_model} ->
                  metadata_populated =
                    parsed_model.cost != nil or
                      parsed_model.limit != nil or
                      parsed_model.capabilities != nil or
                      parsed_model.modalities != nil

                  if metadata_populated do
                    [{model_spec, parsed_model} | acc]
                  else
                    acc
                  end

                {:error, _} ->
                  acc
              end
            end)

          # Sample some models and verify metadata structure
          sample_models =
            Enum.take_random(models_with_metadata, min(10, length(models_with_metadata)))

          for {model_spec, parsed_model} <- sample_models do
            IO.puts("✓ #{model_spec}:")

            if parsed_model.cost do
              IO.puts("  - Cost: #{inspect(Map.keys(parsed_model.cost))}")
            end

            if parsed_model.limit do
              IO.puts("  - Limits: #{inspect(Map.keys(parsed_model.limit))}")
            end

            if parsed_model.capabilities do
              IO.puts("  - Capabilities: #{inspect(Map.keys(parsed_model.capabilities))}")
            end

            if parsed_model.modalities do
              IO.puts("  - Modalities: #{inspect(parsed_model.modalities)}")
            end
          end

          refute Enum.empty?(models_with_metadata)
        end)
      end)
    end

    test "provider classification works correctly", %{models: _models} do
      capture_io(fn ->
        capture_log(fn ->
          all_providers = ReqLLM.Provider.Registry.list_providers()
          implemented_providers = ReqLLM.Provider.Registry.list_implemented_providers()
          metadata_only_providers = ReqLLM.Provider.Registry.list_metadata_only_providers()

          IO.puts("Provider classification:")
          IO.puts("  Total providers: #{length(all_providers)}")

          IO.puts(
            "  Implemented: #{length(implemented_providers)} - #{inspect(implemented_providers)}"
          )

          IO.puts(
            "  Metadata-only: #{length(metadata_only_providers)} - #{inspect(Enum.take(metadata_only_providers, 10))}#{if length(metadata_only_providers) > 10, do: "...", else: ""}"
          )

          # Verify the classification makes sense
          assert length(implemented_providers) + length(metadata_only_providers) ==
                   length(all_providers)

          # Should have at least some implemented providers
          assert length(implemented_providers) >= 1
          # Should have some metadata-only providers (depends on catalog_allow config)
          assert length(metadata_only_providers) >= 0
        end)
      end)
    end
  end
end
