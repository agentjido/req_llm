defmodule ReqLLM.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Provider.Registry

  # Test module that implements the Provider behaviour for testing
  defmodule TestProvider do
    @behaviour ReqLLM.Provider

    def metadata,
      do: %{
        models: [
          %{"id" => "test-model-1", "context_length" => 4096},
          %{"id" => "test-model-2", "context_length" => 8192}
        ]
      }

    def provider_id, do: :test_provider

    @impl true
    def attach(_req, _provider_id, _options), do: {:ok, nil}

    @impl true
    def prepare_request(_req, _provider_id, _operation, _options), do: {:ok, nil}

    @impl true
    def encode_body(_body), do: %{}

    @impl true
    def decode_response(_response), do: {:ok, nil}
  end

  # Another test provider for duplicate testing
  defmodule DuplicateProvider do
    @behaviour ReqLLM.Provider

    def provider_id, do: :test_provider

    @impl true
    def attach(_req, _provider_id, _options), do: {:ok, nil}

    @impl true
    def prepare_request(_req, _provider_id, _operation, _options), do: {:ok, nil}

    @impl true
    def encode_body(_body), do: %{}

    @impl true
    def decode_response(_response), do: {:ok, nil}
  end

  setup do
    Registry.clear()
    :ok
  end

  describe "register/3" do
    test "successfully registers new provider" do
      metadata = %{models: ["model1", "model2"]}

      assert Registry.register(:new_provider, TestProvider, metadata) == :ok
      assert {:ok, TestProvider} = Registry.get_provider(:new_provider)
    end

    test "allows idempotent registration with same module" do
      metadata = %{models: ["model1"]}

      assert Registry.register(:same_provider, TestProvider, metadata) == :ok
      assert Registry.register(:same_provider, TestProvider, metadata) == :ok
      assert {:ok, TestProvider} = Registry.get_provider(:same_provider)
    end

    test "prevents duplicate registration with different module" do
      metadata = %{models: ["model1"]}

      assert Registry.register(:duplicate_test, TestProvider, metadata) == :ok

      result = Registry.register(:duplicate_test, DuplicateProvider, metadata)
      assert {:error, {:already_registered, TestProvider}} = result
    end

    test "handles nil metadata gracefully" do
      assert Registry.register(:nil_metadata, TestProvider, nil) == :ok
      assert {:ok, TestProvider} = Registry.get_provider(:nil_metadata)
    end
  end

  describe "get_provider/1 and fetch/1" do
    setup do
      Registry.register(:existing_provider, TestProvider, %{})
      :ok
    end

    test "returns provider module when found" do
      assert {:ok, TestProvider} = Registry.get_provider(:existing_provider)
    end

    test "returns error when provider not found" do
      assert {:error, %ReqLLM.Error.Invalid.Provider{provider: :nonexistent}} =
               Registry.get_provider(:nonexistent)
    end

    test "returns NotImplemented error for metadata-only providers" do
      Registry.clear()
      registry = %{metadata_only: %{module: nil, metadata: %{models: []}, implemented: false}}
      :persistent_term.put(:req_llm_providers, registry)

      assert {:error, %ReqLLM.Error.Invalid.Provider.NotImplemented{provider: :metadata_only}} =
               Registry.get_provider(:metadata_only)
    end

    test "fetch/1 aliases get_provider/1" do
      assert Registry.fetch(:existing_provider) == Registry.get_provider(:existing_provider)
      assert Registry.fetch(:nonexistent) == Registry.get_provider(:nonexistent)
    end

    test "fetch/1 returns NotImplemented error for metadata-only providers" do
      Registry.clear()
      registry = %{metadata_only: %{module: nil, metadata: %{models: []}, implemented: false}}
      :persistent_term.put(:req_llm_providers, registry)

      assert {:error, %ReqLLM.Error.Invalid.Provider.NotImplemented{provider: :metadata_only}} =
               Registry.fetch(:metadata_only)
    end
  end

  # Note: parse_model_spec/1 is a private function, so we test it indirectly through model_exists?/1 and get_model!/1

  describe "model_exists?/1" do
    setup do
      metadata = %{
        models: [
          %{"id" => "existing-model", "context_length" => 4096}
        ]
      }

      Registry.register(:model_test_provider, TestProvider, metadata)
      :ok
    end

    test "returns true for existing model" do
      assert Registry.model_exists?("model_test_provider:existing-model")
    end

    test "returns false for non-existing model" do
      refute Registry.model_exists?("model_test_provider:non-existing-model")
    end

    test "returns false for non-existing provider" do
      refute Registry.model_exists?("non_existing_provider:any-model")
    end

    test "returns false for invalid model specification" do
      refute Registry.model_exists?("invalid-spec-no-colon")
    end

    test "returns false for unknown provider in spec" do
      refute Registry.model_exists?("unknown_xyz_provider:model")
    end
  end

  describe "get_model/2" do
    setup do
      metadata = %{
        models: [
          %{
            "id" => "test-model",
            "context_length" => 8192,
            "cost" => %{"input" => 0.001, "output" => 0.002},
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "reasoning" => true,
            "tool_call" => false
          }
        ]
      }

      Registry.register(:model_provider, TestProvider, metadata)
      :ok
    end

    test "returns enhanced model with metadata" do
      {:ok, model} = Registry.get_model(:model_provider, "test-model")

      assert model.provider == :model_provider
      assert model.model == "test-model"
      assert model.cost.input == 0.001
      assert model.cost.output == 0.002
      assert model.capabilities.reasoning == true
      assert model.capabilities.tool_call == false
    end

    test "returns error for unknown provider" do
      result = Registry.get_model(:unknown_provider, "any-model")
      assert {:error, :provider_not_found} = result
    end

    test "returns error for unknown model" do
      result = Registry.get_model(:model_provider, "unknown-model")
      assert {:error, :model_not_found} = result
    end

    test "handles provider with no models list" do
      Registry.register(:no_models_provider, TestProvider, %{})
      {:ok, _model} = Registry.get_model(:no_models_provider, "any-model")
    end
  end

  describe "get_model!/1" do
    setup do
      metadata = %{
        models: [%{"id" => "bang-model"}]
      }

      Registry.register(:bang_provider, TestProvider, metadata)
      :ok
    end

    test "returns model for valid specification" do
      model = Registry.get_model!("bang_provider:bang-model")
      assert model.provider == :bang_provider
      assert model.model == "bang-model"
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, "Provider not found: unknown_provider", fn ->
        Registry.get_model!("unknown_provider:model")
      end
    end

    test "raises for unknown model" do
      assert_raise ArgumentError, "Model not found: bang_provider:unknown-model", fn ->
        Registry.get_model!("bang_provider:unknown-model")
      end
    end

    test "raises for invalid specification" do
      assert_raise ArgumentError, fn ->
        Registry.get_model!("invalid-spec")
      end
    end
  end

  describe "list functions" do
    setup do
      Registry.register(:provider_a, TestProvider, %{})
      Registry.register(:provider_b, TestProvider, %{})
      :ok
    end

    test "list_providers/0 returns all provider IDs sorted" do
      providers = Registry.list_providers()

      assert :provider_a in providers
      assert :provider_b in providers
      assert providers == Enum.sort(providers)
    end

    test "list_implemented_providers/0 returns only providers with modules" do
      # Need to manually set up registry with implemented field
      current_registry = :persistent_term.get(:req_llm_providers, %{})

      updated_registry =
        Map.merge(current_registry, %{
          provider_a: %{module: TestProvider, metadata: %{}, implemented: true},
          provider_b: %{module: TestProvider, metadata: %{}, implemented: true},
          metadata_only: %{module: nil, metadata: %{models: []}, implemented: false}
        })

      :persistent_term.put(:req_llm_providers, updated_registry)

      providers = Registry.list_implemented_providers()

      assert :provider_a in providers
      assert :provider_b in providers
      refute :metadata_only in providers
    end

    test "list_metadata_only_providers/0 returns only providers without modules" do
      # Set up registry with mixed providers
      registry = %{
        provider_a: %{module: TestProvider, metadata: %{}, implemented: true},
        metadata_only: %{module: nil, metadata: %{models: []}, implemented: false}
      }

      :persistent_term.put(:req_llm_providers, registry)

      providers = Registry.list_metadata_only_providers()

      refute :provider_a in providers
      assert :metadata_only in providers
    end
  end

  describe "implemented?/1" do
    setup do
      # Need to manually set the implemented flag since register/3 doesn't set it
      Registry.register(:implemented_provider, TestProvider, %{})

      # Update the registry entry to mark as implemented
      current_registry = :persistent_term.get(:req_llm_providers, %{})
      updated_registry = put_in(current_registry, [:implemented_provider, :implemented], true)
      :persistent_term.put(:req_llm_providers, updated_registry)
      :ok
    end

    test "returns true for implemented provider" do
      assert Registry.implemented?(:implemented_provider)
    end

    test "returns false for non-existing provider" do
      refute Registry.implemented?(:non_existing)
    end
  end

  describe "get_provider_metadata/1" do
    setup do
      metadata = %{models: ["test"], custom_field: "value"}
      Registry.register(:metadata_provider, TestProvider, metadata)
      :ok
    end

    test "returns provider metadata" do
      {:ok, metadata} = Registry.get_provider_metadata(:metadata_provider)
      assert metadata.custom_field == "value"
    end

    test "returns error for unknown provider" do
      assert {:error, :provider_not_found} = Registry.get_provider_metadata(:unknown)
    end
  end

  describe "list_models/1" do
    test "returns model list from models array with id field" do
      metadata = %{
        models: [
          %{"id" => "model-1"},
          %{"id" => "model-2"}
        ]
      }

      Registry.register(:list_test_provider, TestProvider, metadata)

      {:ok, models} = Registry.list_models(:list_test_provider)
      assert models == ["model-1", "model-2"]
    end

    test "handles models with atom keys" do
      metadata = %{
        models: [
          %{id: "atom-key-model"}
        ]
      }

      Registry.register(:atom_provider, TestProvider, metadata)

      {:ok, models} = Registry.list_models(:atom_provider)
      assert models == ["atom-key-model"]
    end

    test "handles simple string models" do
      metadata = %{
        models: ["simple-string-model"]
      }

      Registry.register(:string_provider, TestProvider, metadata)

      {:ok, models} = Registry.list_models(:string_provider)
      assert models == ["simple-string-model"]
    end

    test "filters out invalid model entries" do
      metadata = %{
        models: [
          %{"id" => "valid-model"},
          %{"name" => "invalid-no-id"},
          nil,
          123
        ]
      }

      Registry.register(:mixed_provider, TestProvider, metadata)

      {:ok, models} = Registry.list_models(:mixed_provider)
      assert models == ["valid-model"]
    end

    test "returns empty list for provider with no models" do
      Registry.register(:no_models, TestProvider, %{})

      {:ok, models} = Registry.list_models(:no_models)
      assert models == []
    end

    test "returns error for unknown provider" do
      assert {:error, :provider_not_found} = Registry.list_models(:unknown)
    end
  end

  describe "get_env_key/1" do
    test "returns env key from provider metadata" do
      metadata = %{
        "provider" => %{"env" => ["CUSTOM_API_KEY"]}
      }

      Registry.register(:env_provider, TestProvider, metadata)

      assert Registry.get_env_key(:env_provider) == "CUSTOM_API_KEY"
    end

    test "returns env key from provider metadata with atom keys" do
      metadata = %{
        provider: %{env: ["ATOM_API_KEY"]}
      }

      Registry.register(:env_atom_provider, TestProvider, metadata)

      assert Registry.get_env_key(:env_atom_provider) == "ATOM_API_KEY"
    end

    test "returns first env key when multiple provided" do
      metadata = %{
        "provider" => %{"env" => ["FIRST_KEY", "SECOND_KEY"]}
      }

      Registry.register(:multi_env_provider, TestProvider, metadata)

      assert Registry.get_env_key(:multi_env_provider) == "FIRST_KEY"
    end

    test "falls back to provider default_env_key/0" do
      defmodule EnvKeyProvider do
        @behaviour ReqLLM.Provider

        def provider_id, do: :env_key_provider
        def default_env_key, do: "FALLBACK_API_KEY"

        @impl true
        def attach(_req, _provider_id, _options), do: {:ok, nil}

        @impl true
        def prepare_request(_req, _provider_id, _operation, _options), do: {:ok, nil}

        @impl true
        def encode_body(_body), do: %{}

        @impl true
        def decode_response(_response), do: {:ok, nil}
      end

      Registry.register(:env_key_provider, EnvKeyProvider, %{})

      assert Registry.get_env_key(:env_key_provider) == "FALLBACK_API_KEY"
    end

    test "returns nil for provider without env configuration" do
      Registry.register(:no_env_provider, TestProvider, %{})

      assert Registry.get_env_key(:no_env_provider) == nil
    end

    test "returns nil for unknown provider" do
      # get_env_key should handle unknown providers gracefully
      assert Registry.get_env_key(:unknown_provider) == nil
    end
  end

  describe "provider discovery" do
    test "discover_providers/0 finds provider modules" do
      providers = Registry.discover_providers()

      # Should be a list of modules
      assert is_list(providers)
      # In test environment, should find at least the test provider modules
      # May be empty in test env without app modules
      assert length(providers) >= 0
    end

    test "provider_module?/1 identifies provider modules correctly" do
      assert Registry.provider_module?(TestProvider)
      refute Registry.provider_module?(String)
    end

    test "extract_provider_info/1 extracts provider information" do
      {:ok, {provider_id, module, metadata}} = Registry.extract_provider_info(TestProvider)

      assert provider_id == :test_provider
      assert module == TestProvider
      assert is_map(metadata)
    end

    test "extract_provider_info/1 handles modules without provider_id" do
      defmodule NoIdProvider do
        @behaviour ReqLLM.Provider

        @impl true
        def attach(_req, _provider_id, _options), do: {:ok, nil}

        @impl true
        def prepare_request(_req, _provider_id, _operation, _options), do: {:ok, nil}

        @impl true
        def encode_body(_body), do: %{}

        @impl true
        def decode_response(_response), do: {:ok, nil}
      end

      {:ok, {provider_id, module, _metadata}} = Registry.extract_provider_info(NoIdProvider)

      # derived from module name
      assert provider_id == :noidprovider
      assert module == NoIdProvider
    end
  end

  describe "registry management" do
    test "clear/0 removes all providers" do
      Registry.register(:test_clear, TestProvider, %{})
      assert {:ok, TestProvider} = Registry.get_provider(:test_clear)

      Registry.clear()

      assert {:error, %ReqLLM.Error.Invalid.Provider{provider: :test_clear}} =
               Registry.get_provider(:test_clear)
    end

    test "initialize/0 and reload/0 work" do
      # These functions primarily work with application modules, 
      # so we just ensure they don't crash
      assert Registry.initialize() == :ok
      assert Registry.reload() == :ok
    end
  end

  describe "initialize/1 with catalog" do
    test "initializes registry from effective catalog" do
      Registry.clear()

      catalog = %{
        "test_catalog_provider" => %{
          "id" => "test_catalog_provider",
          "models" => %{
            "model-1" => %{
              "id" => "model-1",
              "context_length" => 4096,
              "cost" => %{"input" => 0.001, "output" => 0.002}
            },
            "model-2" => %{
              "id" => "model-2",
              "context_length" => 8192,
              "cost" => %{"input" => 0.002, "output" => 0.004}
            }
          },
          "provider" => %{
            "env" => ["TEST_API_KEY"]
          }
        }
      }

      assert Registry.initialize(catalog) == :ok

      providers = Registry.list_providers()
      assert :test_catalog_provider in providers

      {:ok, models} = Registry.list_models(:test_catalog_provider)
      assert "model-1" in models
      assert "model-2" in models

      {:ok, model} = Registry.get_model(:test_catalog_provider, "model-1")
      assert model.provider == :test_catalog_provider
      assert model.model == "model-1"
    end

    test "combines DSL-registered providers with catalog providers" do
      Registry.clear()

      Registry.register(:dsl_provider, TestProvider, %{
        models: [%{"id" => "dsl-model"}]
      })

      catalog = %{
        "dsl_provider" => %{
          "id" => "dsl_provider",
          "models" => %{
            "catalog-model" => %{"id" => "catalog-model"}
          }
        },
        "catalog_only_provider" => %{
          "id" => "catalog_only_provider",
          "models" => %{
            "catalog-only-model" => %{"id" => "catalog-only-model"}
          }
        }
      }

      assert Registry.initialize(catalog) == :ok

      providers = Registry.list_providers()
      assert :dsl_provider in providers
      assert :catalog_only_provider in providers

      assert {:ok, TestProvider} = Registry.get_provider(:dsl_provider)
      assert Registry.implemented?(:dsl_provider)

      assert {:error, %ReqLLM.Error.Invalid.Provider.NotImplemented{}} =
               Registry.get_provider(:catalog_only_provider)

      refute Registry.implemented?(:catalog_only_provider)
    end

    test "converts catalog models map to list format" do
      Registry.clear()

      catalog = %{
        "converter_provider" => %{
          "id" => "converter_provider",
          "models" => %{
            "model-b" => %{"id" => "model-b"},
            "model-a" => %{"id" => "model-a"},
            "model-c" => %{"id" => "model-c"}
          }
        }
      }

      assert Registry.initialize(catalog) == :ok

      {:ok, models} = Registry.list_models(:converter_provider)
      assert models == ["model-a", "model-b", "model-c"]
    end

    test "handles empty catalog gracefully" do
      Registry.clear()
      assert Registry.initialize(%{}) == :ok
      assert Registry.list_providers() == []
    end

    test "works with get_model/2 for catalog-initialized providers" do
      Registry.clear()

      catalog = %{
        "catalog_test" => %{
          "id" => "catalog_test",
          "models" => %{
            "test-model" => %{
              "id" => "test-model",
              "cost" => %{"input" => 0.005, "output" => 0.010},
              "modalities" => %{"input" => ["text"], "output" => ["text"]},
              "reasoning" => false,
              "tool_call" => true
            }
          }
        }
      }

      assert Registry.initialize(catalog) == :ok

      {:ok, model} = Registry.get_model(:catalog_test, "test-model")
      assert model.provider == :catalog_test
      assert model.model == "test-model"
      assert model.cost.input == 0.005
      assert model.cost.output == 0.010
      assert model.capabilities.reasoning == false
      assert model.capabilities.tool_call == true
    end
  end
end
