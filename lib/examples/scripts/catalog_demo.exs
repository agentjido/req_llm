defmodule CatalogDemo do
  @moduledoc """
  Demonstration script for the ReqLLM Catalog system.

  Shows how the catalog:
  1. Loads base metadata from compile-time
  2. Applies allowlist filtering
  3. Merges custom providers/models
  4. Applies overrides to metadata

  Run with: mix run lib/examples/scripts/catalog_demo.exs
  """

  def run do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("ReqLLM Catalog System Demo")
    IO.puts(String.duplicate("=", 80) <> "\n")

    demonstrate_base_catalog()
    demonstrate_allowlist_filtering()
    demonstrate_custom_providers()
    demonstrate_overrides()
    demonstrate_full_pipeline()
    demonstrate_registry_integration()

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Demo Complete!")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  defp demonstrate_base_catalog do
    section("1. Base Catalog (Compile-Time)")

    base = ReqLLM.Catalog.Base.base()

    IO.puts("Total providers in base catalog: #{map_size(base)}")
    IO.puts("\nSample providers:")

    base
    |> Map.keys()
    |> Enum.take(5)
    |> Enum.each(fn provider_id ->
      provider = base[provider_id]
      model_count = map_size(provider["models"] || %{})
      IO.puts("  • #{provider_id}: #{model_count} models")
    end)

    IO.puts("\nOpenAI models sample:")

    if base["openai"] do
      base["openai"]["models"]
      |> Map.keys()
      |> Enum.take(3)
      |> Enum.each(fn model_id ->
        model = base["openai"]["models"][model_id]
        IO.puts("    - #{model_id}")
        IO.puts("      Name: #{model["name"]}")

        if model["cost"] do
          IO.puts(
            "      Cost: $#{model["cost"]["input"]}/M input, $#{model["cost"]["output"]}/M output"
          )
        end
      end)
    end
  end

  defp demonstrate_allowlist_filtering do
    section("2. Allowlist Filtering")

    config = %{
      allow: %{
        openai: ["gpt-4o", "gpt-4o-mini"],
        anthropic: ["claude-3-5-sonnet-20241022"]
      },
      overrides: [],
      custom: []
    }

    IO.puts("Allowlist configuration:")
    IO.puts("  OpenAI: #{inspect(config.allow.openai)}")
    IO.puts("  Anthropic: #{inspect(config.allow.anthropic)}")

    case ReqLLM.Catalog.load(config) do
      {:ok, catalog} ->
        IO.puts("\n✓ Filtered catalog loaded successfully")
        IO.puts("  Providers: #{Map.keys(catalog) |> Enum.join(", ")}")

        Enum.each(catalog, fn {provider_id, provider_data} ->
          model_count = map_size(provider_data["models"] || %{})
          models = Map.keys(provider_data["models"] || %{}) |> Enum.join(", ")
          IO.puts("  #{provider_id}: #{model_count} models (#{models})")
        end)

      {:error, error} ->
        IO.puts("\n✗ Error: #{inspect(error)}")
    end
  end

  defp demonstrate_custom_providers do
    section("3. Custom Providers")

    config = %{
      allow: %{
        openai: ["gpt-4o-mini"],
        vllm: ["llama-3.2-3b-instruct"]
      },
      overrides: [],
      custom: [
        %{
          provider: %{
            id: "vllm",
            name: "vLLM Local",
            base_url: "http://localhost:8000",
            env: ["VLLM_API_KEY"]
          },
          models: [
            %{
              id: "llama-3.2-3b-instruct",
              name: "LLaMA 3.2 3B Instruct",
              modalities: %{
                "input" => ["text"],
                "output" => ["text"]
              },
              limit: %{
                "context" => 8192
              },
              cost: %{
                "input" => 0.0,
                "output" => 0.0
              }
            }
          ]
        }
      ]
    }

    IO.puts("Custom provider configuration:")
    IO.puts("  Provider: vLLM Local")
    IO.puts("  Base URL: http://localhost:8000")
    IO.puts("  Model: llama-3.2-3b-instruct")

    case ReqLLM.Catalog.load(config) do
      {:ok, catalog} ->
        IO.puts("\n✓ Catalog with custom provider loaded")
        IO.puts("  Providers: #{Map.keys(catalog) |> Enum.join(", ")}")

        if catalog["vllm"] do
          vllm_models = Map.keys(catalog["vllm"]["models"] || %{})
          IO.puts("\n  vLLM provider details:")
          IO.puts("    Base URL: #{catalog["vllm"]["base_url"]}")
          IO.puts("    Models: #{Enum.join(vllm_models, ", ")}")

          if catalog["vllm"]["models"]["llama-3.2-3b-instruct"] do
            model = catalog["vllm"]["models"]["llama-3.2-3b-instruct"]
            IO.puts("    Model '#{model["id"]}':")
            IO.puts("      Name: #{model["name"]}")
            IO.puts("      Context: #{model["limit"]["context"]} tokens")
            IO.puts("      Cost: FREE (local)")
          end
        end

      {:error, error} ->
        IO.puts("\n✗ Error: #{inspect(error)}")
    end
  end

  defp demonstrate_overrides do
    section("4. Metadata Overrides")

    config = %{
      allow: %{
        openai: ["gpt-4o-mini"],
        anthropic: ["claude-3-5-haiku-20241022"]
      },
      overrides: [
        providers: %{
          openai: %{
            "base_url" => "https://api.custom-proxy.com/v1"
          }
        },
        models: %{
          openai: %{
            "gpt-4o-mini" => %{
              "cost" => %{
                "input" => 0.00010,
                "output" => 0.00040
              }
            }
          },
          anthropic: %{
            "claude-3-5-haiku-20241022" => %{
              "cost" => %{
                "input" => 0.50,
                "output" => 2.00
              }
            }
          }
        }
      ],
      custom: []
    }

    IO.puts("Override configuration:")
    IO.puts("  Provider override: OpenAI base_url → https://api.custom-proxy.com/v1")
    IO.puts("  Model override: gpt-4o-mini cost → $0.10/$0.40 per M tokens")
    IO.puts("  Model override: claude-3-5-haiku-20241022 cost → $0.50/$2.00 per M tokens")

    base = ReqLLM.Catalog.Base.base()
    original_openai = base["openai"]
    original_gpt4o_mini = if original_openai, do: original_openai["models"]["gpt-4o-mini"]

    case ReqLLM.Catalog.load(config) do
      {:ok, catalog} ->
        IO.puts("\n✓ Catalog with overrides loaded")

        if catalog["openai"] do
          IO.puts("\n  OpenAI provider:")
          IO.puts("    Original base_url: #{original_openai["base_url"]}")
          IO.puts("    Override base_url: #{catalog["openai"]["base_url"]}")

          if catalog["openai"]["models"]["gpt-4o-mini"] do
            model = catalog["openai"]["models"]["gpt-4o-mini"]
            IO.puts("\n  GPT-4o-mini model:")

            if original_gpt4o_mini && original_gpt4o_mini["cost"] do
              IO.puts(
                "    Original cost: $#{original_gpt4o_mini["cost"]["input"]}/$#{original_gpt4o_mini["cost"]["output"]} per M"
              )
            end

            IO.puts(
              "    Override cost: $#{model["cost"]["input"]}/$#{model["cost"]["output"]} per M"
            )
          end
        end

        if catalog["anthropic"] && catalog["anthropic"]["models"]["claude-3-5-haiku-20241022"] do
          model = catalog["anthropic"]["models"]["claude-3-5-haiku-20241022"]
          IO.puts("\n  Claude 3.5 Haiku:")

          IO.puts(
            "    Override cost: $#{model["cost"]["input"]}/$#{model["cost"]["output"]} per M"
          )
        end

      {:error, error} ->
        IO.puts("\n✗ Error: #{inspect(error)}")
    end
  end

  defp demonstrate_full_pipeline do
    section("5. Full Pipeline (Allowlist + Custom + Overrides)")

    config = %{
      allow: %{
        openai: ["gpt-4o"],
        anthropic: ["claude-3-5-sonnet-20241022"],
        local: ["my-custom-model"]
      },
      overrides: [
        models: %{
          openai: %{
            "gpt-4o" => %{
              "limit" => %{
                "context" => 200_000
              }
            }
          }
        }
      ],
      custom: [
        %{
          provider: %{
            id: "local",
            name: "Local Inference",
            base_url: "http://localhost:11434",
            env: []
          },
          models: [
            %{
              id: "my-custom-model",
              name: "My Custom Fine-tuned Model",
              modalities: %{"input" => ["text"], "output" => ["text"]},
              limit: %{"context" => 4096},
              cost: %{"input" => 0.0, "output" => 0.0}
            }
          ]
        }
      ]
    }

    IO.puts("Complete configuration:")

    IO.puts(
      "  Allowlist: OpenAI (gpt-4o), Anthropic (claude-3-5-sonnet), Local (my-custom-model)"
    )

    IO.puts("  Custom: Local inference server at localhost:11434")
    IO.puts("  Override: gpt-4o context → 200k tokens")

    case ReqLLM.Catalog.load(config) do
      {:ok, catalog} ->
        IO.puts("\n✓ Full catalog pipeline completed")
        IO.puts("\nFinal catalog summary:")

        total_models =
          catalog
          |> Enum.map(fn {_id, provider} -> map_size(provider["models"] || %{}) end)
          |> Enum.sum()

        IO.puts("  Total providers: #{map_size(catalog)}")
        IO.puts("  Total models: #{total_models}")

        IO.puts("\nProvider breakdown:")

        Enum.each(catalog, fn {provider_id, provider_data} ->
          model_count = map_size(provider_data["models"] || %{})
          models = Map.keys(provider_data["models"] || %{})
          IO.puts("  • #{provider_id} (#{provider_data["name"]}): #{model_count} models")

          Enum.each(models, fn model_id ->
            model = provider_data["models"][model_id]
            context = get_in(model, ["limit", "context"]) || "N/A"
            IO.puts("    - #{model_id}: #{context} tokens context")
          end)
        end)

      {:error, error} ->
        IO.puts("\n✗ Error: #{inspect(error)}")
    end
  end

  defp demonstrate_registry_integration do
    section("6. Registry Integration")

    config = %{
      allow: %{
        openai: ["gpt-4o-mini"],
        anthropic: ["claude-3-5-haiku-20241022"]
      },
      overrides: [],
      custom: []
    }

    IO.puts("Loading catalog into Registry...")

    case ReqLLM.Catalog.load(config) do
      {:ok, catalog} ->
        IO.puts("✓ Catalog loaded successfully")

        # Initialize registry with catalog
        :ok = ReqLLM.Provider.Registry.initialize(catalog)
        IO.puts("✓ Registry initialized with catalog")

        # Test registry API
        IO.puts("\nTesting Registry API:")

        providers = ReqLLM.Provider.Registry.list_providers()
        IO.puts("  list_providers(): #{inspect(providers)}")

        case ReqLLM.Provider.Registry.get_model(:openai, "gpt-4o-mini") do
          {:ok, model} ->
            IO.puts("\n  ✓ get_model(:openai, \"gpt-4o-mini\") succeeded")
            IO.puts("    Model struct: #{model.model}")
            IO.puts("    Provider: #{model.provider}")

            if model._metadata do
              IO.puts("    Name: #{model._metadata["name"] || "N/A"}")
            end

            if model.cost do
              IO.puts("    Cost: $#{model.cost.input}/$#{model.cost.output} per M")
            end

          {:error, reason} ->
            IO.puts("\n  ✗ get_model failed: #{inspect(reason)}")
        end

        case ReqLLM.Provider.Registry.get_model(:openai, "gpt-4-turbo") do
          {:ok, _model} ->
            IO.puts(
              "\n  ✗ get_model(:openai, \"gpt-4-turbo\") should have failed (not in allowlist)"
            )

          {:error, :model_not_found} ->
            IO.puts(
              "\n  ✓ get_model(:openai, \"gpt-4-turbo\") correctly returns :model_not_found"
            )

            IO.puts("    (Model filtered out by allowlist)")
        end

      {:error, error} ->
        IO.puts("✗ Catalog load failed: #{inspect(error)}")
    end
  end

  defp section(title) do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts(title)
    IO.puts(String.duplicate("-", 80))
  end
end

# Run the demo
CatalogDemo.run()
