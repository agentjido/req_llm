# ReqLLM Catalog System - Design & Implementation Plan

## Problem Statement

### Current Behavior
The model synchronization system currently works as follows:
1. `mix req_llm.model_sync` fetches metadata from models.dev API
2. Raw metadata is stored in `priv/models_dev/*.json` files
3. Provider Registry automatically loads ALL JSON files at application startup
4. All models from models.dev immediately become available in the system

### Issues
1. **No control over model availability**: When models.dev adds a new model, it automatically appears in ReqLLM after sync, potentially causing test failures
2. **No override mechanism**: Cannot modify or correct metadata before it enters the system
3. **No custom model support**: Cannot easily define local models (VLLM, LLaMA CPP) without creating full provider implementations
4. **All-or-nothing loading**: Cannot selectively enable/disable specific providers or models

### Use Cases
1. **Explicit model allowlisting**: New models from models.dev should not appear until explicitly approved and tested
2. **Metadata corrections**: Override incorrect pricing, context limits, or other metadata from upstream
3. **Local model support**: Define VLLM, LLaMA CPP, or other local models via simple configuration

## Proposed Solution

### Architecture Overview

Introduce a **Catalog** layer that sits between raw model metadata sources and the Provider Registry. The Catalog is responsible for:
- Loading metadata from base sources (models.dev snapshots in priv/)
- Merging custom provider/model definitions from config
- Applying model-level allowlist filtering
- Applying metadata overrides
- Producing the "effective catalog" used by the rest of the system

```
┌─────────────────────────────────────────────────────────────┐
│                     Data Flow                                │
└─────────────────────────────────────────────────────────────┘

Dev-time (mix task):
  models.dev API → priv/models_dev/*.json (raw, unfiltered)

Runtime (app start):
  priv/models_dev/*.json + config.custom
    ↓
  Catalog.load() → filter by config.allow → apply config.overrides
    ↓
  Registry.initialize(effective_catalog) → persistent_term storage
    ↓
  Application code uses Registry API
```

### Key Principles

1. **Always Explicit**: Only explicitly allowed models are loaded - no automatic discovery
2. **Single Override Path**: Configuration is the only way to override or extend metadata
3. **Clear Separation**: Dev-time task (model_sync) only fetches; runtime (Catalog) does all curation
4. **Configuration-Driven**: All control via `config.exs` (no code changes needed for common cases)
5. **Simple Surface**: Three config keys only - `allow`, `overrides`, `custom`

## Configuration Structure

### Full Configuration Example

```elixir
# config/config.exs
config :req_llm, :catalog,
  # Model allowlist (REQUIRED) - only these models will be available
  # Map of provider_id => list of model IDs
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini gpt-3.5-turbo),
    anthropic: ~w(claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022),
    google: ~w(gemini-1.5-pro gemini-1.5-flash),
    groq: ~w(llama-3.2-3b-preview),
    xai: ~w(grok-2-1212)
  },

  # Metadata overrides (OPTIONAL) - correct or update upstream metadata
  overrides: [
    # Provider-level overrides (deep merged, fields are flattened)
    providers: %{
      openai: %{
        "base_url" => "https://api.openai.com/v1/custom"
      }
    },
    
    # Model-level overrides (deep merged into model metadata)
    models: %{
      openai: %{
        "gpt-4o-mini" => %{
          "cost" => %{
            "input" => 0.00015,
            "output" => 0.0006
          },
          "limit" => %{
            "context" => 128_000
          }
        }
      },
      anthropic: %{
        "claude-3-5-sonnet-20241022" => %{
          "cost" => %{
            "input" => 0.003,
            "output" => 0.015
          }
        }
      }
    }
  ],

  # Custom providers/models (OPTIONAL) - define local models
  custom: [
    %{
      provider: %{
        id: :vllm,
        name: "vLLM",
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
    },
    %{
      provider: %{
        id: :llamacpp,
        name: "LLaMA CPP",
        base_url: "http://localhost:8080",
        env: []
      },
      models: [
        %{
          id: "qwen2.5-7b-instruct-q4",
          name: "Qwen 2.5 7B Instruct Q4",
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
```

### Minimal Configuration Examples

#### Example 1: Basic allowlist (most common)
```elixir
config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini),
    anthropic: ~w(claude-3-5-sonnet-20241022)
  }
```

#### Example 2: Allowlist + custom local models
```elixir
config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o),
    vllm: ~w(llama-3.2-3b-instruct)
  },
  custom: [
    %{
      provider: %{id: :vllm, name: "vLLM", base_url: "http://localhost:8000", env: []},
      models: [
        %{id: "llama-3.2-3b-instruct", modalities: %{"input" => ["text"], "output" => ["text"]},
          limit: %{"context" => 8192}, cost: %{"input" => 0.0, "output" => 0.0}}
      ]
    }
  ]
```

#### Example 3: Allowlist + pricing overrides
```elixir
config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini)
  },
  overrides: [
    models: %{
      openai: %{
        "gpt-4o-mini" => %{"cost" => %{"input" => 0.00015, "output" => 0.0006}}
      }
    }
  ]
```

## Implementation Plan

### Phase 1: Compile-Time Base Catalog

**File**: `lib/req_llm/catalog/base.ex` (NEW)

**Purpose**: Pre-compile the base catalog from JSON files to eliminate runtime I/O and parsing.

```elixir
defmodule ReqLLM.Catalog.Base do
  @moduledoc """
  Compile-time base catalog built from priv/models_dev/*.json.
  
  Recompiles when manifest changes (updated by mix req_llm.model_sync).
  """
  
  @manifest Path.expand("priv/models_dev/.catalog_manifest.json", __DIR__)
  @external_resource @manifest
  
  # Load file list from manifest
  {files, _hash} =
    if File.exists?(@manifest) do
      manifest = @manifest |> File.read!() |> Jason.decode!()
      {manifest["files"] || [], manifest["hash"] || ""}
    else
      {[], ""}
    end
  
  # Track each JSON file for recompilation
  Enum.each(files, &Module.put_attribute(__MODULE__, :external_resource, &1))
  
  # Parse and normalize at compile time
  @base_catalog (
    files
    |> Enum.map(fn file -> file |> File.read!() |> Jason.decode!() end)
    |> Enum.map(&normalize_provider/1)
    |> Enum.into(%{}, fn provider -> {provider["id"], provider} end)
  )
  
  @doc "Returns the normalized base catalog (compiled at build time)"
  @spec base() :: map()
  def base, do: @base_catalog
  
  # Flatten provider structure and convert models array to map
  defp normalize_provider(%{"provider" => prov, "models" => models}) when is_list(models) do
    models_map = Enum.into(models, %{}, fn %{"id" => id} = m -> {id, m} end)
    Map.merge(prov, %{"models" => models_map})
  end
  
  defp normalize_provider(data), do: data
end
```

**Key Points**:
- Uses `@external_resource` to track manifest and all JSON files
- Recompiles when `mix req_llm.model_sync` updates the manifest
- Zero runtime I/O or JSON parsing - catalog is embedded in BEAM bytecode
- Similar pattern to how provider DSL loads metadata

### Phase 2: Runtime Catalog Module

**File**: `lib/req_llm/catalog.ex`

**Public API**:
```elixir
defmodule ReqLLM.Catalog do
  @moduledoc """
  Runtime catalog system that applies configuration to the compile-time base catalog.
  """

  @doc """
  Load the effective catalog by applying allowlist, custom providers, and overrides
  to the compile-time base catalog.
  
  Returns a map: %{provider_id => %{"id" => ..., "models" => %{model_id => ...}}}
  
  Raises if config.allow is empty or missing (except in test environment).
  """
  @spec load(keyword()) :: map()
  def load(opts \\ [])
end
```

**Internal Functions**:
- `merge_custom/2` - Add custom providers/models from config
- `filter_by_allow/2` - Apply allowlist, drop everything not explicitly allowed
- `apply_overrides/2` - Deep merge provider and model overrides (provider overrides cannot touch `"models"` key)
- `deep_merge/2` - Deep merge two maps (for overrides)
- `to_string_keys/1` - Normalize config keys (atoms/strings) to strings
- `validate_allowlist/2` - Warn/raise when allow contains unknown providers/models

**Processing Order** (within `load/0`):
1. Read configuration from `Application.get_env(:req_llm, :catalog, [])`
2. Validate config with NimbleOptions schema
3. Load base catalog from `ReqLLM.Catalog.Base.base()` (compile-time, zero I/O)
4. Merge `config.custom` (custom providers/models replace by ID)
5. Filter by `config.allow` (drop all non-allowed models)
6. Apply `config.overrides.providers` (deep merge, excluding `"models"` key)
7. Apply `config.overrides.models` (deep merge per model)
8. Validate allowlist references (warn on unknown entries)
9. Return effective catalog

### Phase 2: Registry Integration

**File**: `lib/req_llm/provider/registry.ex`

**Changes**:
1. Modify `initialize/0`:
   ```elixir
   def initialize do
     catalog = ReqLLM.Catalog.load()
     
     Enum.each(catalog, fn {provider_id, metadata} ->
       # Check if provider module already registered via DSL
       existing_module = get_provider_module(provider_id)
       register_or_update(provider_id, existing_module, metadata)
     end)
     
     :ok
   end
   ```

2. Add `register_or_update/3` (private):
   - If provider already registered with same module, update metadata
   - If provider not registered, register as metadata-only (module = nil)
   - If conflict (different module for same id), log warning and skip

**No changes needed** to:
- `get_provider/1`
- `get_model/2`
- `list_providers/0`
- `get_env_key/1`

These functions already work with the registry map, so they'll automatically use the filtered/overridden metadata.

### Phase 3: Model Sync Task with Manifest

**File**: `lib/mix/tasks/model_sync.ex`

**Changes**:
1. **Simplify to pure fetch**: Remove all filtering, patching, and override logic
2. Task fetches from models.dev API and writes raw JSON to `priv/models_dev/*.json`
3. **Generate manifest**: Write `priv/models_dev/.catalog_manifest.json` to trigger recompilation
4. Remove `merge_local_patches/2` function (no longer needed)
5. Remove `ValidProviders` module generation (not needed with Catalog)
6. Keep `--verbose` flag for debug output

**Updated flow**:
```elixir
def execute_sync(verbose) do
  raw_data = fetch_models_dev_data(verbose)
  save_provider_files(raw_data, verbose)
  write_manifest(verbose)
  
  IO.puts("✓ Synced #{map_size(raw_data)} providers to priv/models_dev/")
  IO.puts("✓ Updated catalog manifest (will trigger recompilation)")
end

defp write_manifest(verbose) do
  files = Path.wildcard("priv/models_dev/*.json") |> Enum.sort()
  
  # Generate content hash to detect changes
  hash =
    files
    |> Enum.map(&File.read!/1)
    |> Enum.join()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  
  manifest = %{
    "files" => files,
    "hash" => hash,
    "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
  }
  
  File.write!("priv/models_dev/.catalog_manifest.json", Jason.encode!(manifest, pretty: true))
  
  if verbose, do: IO.puts("  Wrote manifest: #{length(files)} files, hash: #{String.slice(hash, 0..7)}")
end
```

**Result**: 
- `priv/models_dev/` contains raw, unfiltered metadata
- Manifest changes trigger `ReqLLM.Catalog.Base` recompilation
- All curation happens at runtime via `Catalog.load/0`

### Phase 4: Configuration Schema

**File**: `lib/req_llm/catalog.ex`

Add NimbleOptions schema for validation:
```elixir
@config_schema NimbleOptions.new!(
  allow: [
    type: :map,
    required: true,
    doc: "Map of provider_id => list of allowed model IDs. Only these models will be available."
  ],
  overrides: [
    type: :keyword_list,
    default: [],
    keys: [
      providers: [type: :map, default: %{}],
      models: [type: :map, default: %{}]
    ],
    doc: "Deep merge patches for provider and model metadata"
  ],
  custom: [
    type: {:list, :map},
    default: [],
    doc: "Custom provider/model definitions (e.g., local VLLM, LLaMA CPP)"
  ]
)
```

Call during `load/0`:
```elixir
def load(opts \\ []) do
  config = 
    Application.get_env(:req_llm, :catalog, [])
    |> NimbleOptions.validate!(@config_schema)
  
  # Raise if allow is empty (except in test env)
  if Map.size(config[:allow]) == 0 and Mix.env() != :test do
    raise ReqLLM.Error.Config, "catalog.allow cannot be empty"
  end
  
  # ... rest of processing
end
```

## Data Structures

### JSON File Format (Storage)
Raw format from models.dev API (stored in `priv/models_dev/*.json`):
```json
{
  "provider": {
    "id": "anthropic",
    "name": "Anthropic",
    "base_url": "https://api.anthropic.com/v1",
    "env": ["ANTHROPIC_API_KEY"]
  },
  "models": [
    {
      "id": "claude-3-5-sonnet-20241022",
      "name": "Claude Sonnet 3.5 v2",
      "modalities": {"input": ["text", "image"], "output": ["text"]},
      "limit": {"context": 200000, "output": 8192},
      "cost": {"input": 3, "output": 15}
    }
  ]
}
```

### Internal Catalog Format
Flattened structure used by Catalog and Registry:
```elixir
%{
  "anthropic" => %{
    "id" => "anthropic",
    "name" => "Anthropic",
    "base_url" => "https://api.anthropic.com/v1",
    "env" => ["ANTHROPIC_API_KEY"],
    "models" => %{
      "claude-3-5-sonnet-20241022" => %{
        "id" => "claude-3-5-sonnet-20241022",
        "name" => "Claude Sonnet 3.5 v2",
        "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
        "limit" => %{"context" => 200000, "output" => 8192},
        "cost" => %{"input" => 3, "output" => 15}
      }
    }
  }
}
```

**Key differences from JSON storage**:
- Provider fields are flattened to top level (no nested `"provider"` key)
- Models array is converted to a map keyed by model ID
- Enables simple path access: `catalog["anthropic"]["base_url"]` and `catalog["anthropic"]["models"]["claude-3-5-sonnet-20241022"]`

### Key Normalization Rules
1. **Provider IDs**: Keys in catalog map are strings (e.g., `"anthropic"`, `"openai"`)
2. **All keys**: Always strings for consistency with JSON and `get_in` paths
3. **Config keys**: Accept both atoms and strings, normalize to strings before merge
4. **Reserved key**: `"models"` is reserved at provider level; cannot be overridden directly

## Testing Strategy

### Unit Tests

**test/req_llm/catalog_test.exs**:
1. `load/1` with no config (backward compat)
2. `load/1` with mode: `:allowlist` and provider allow list
3. `load/1` with mode: `:allowlist` and model allow list
4. `load/1` with mode: `:blocklist` and deny lists
5. `apply_config_overrides/1` with provider overrides
6. `apply_config_overrides/1` with model overrides
7. `merge_config_custom/1` with custom providers
8. Deep merge behavior
9. Key normalization (atom vs string)

### Integration Tests

**test/req_llm/catalog_integration_test.exs**:
1. Registry loads filtered catalog
2. `Registry.get_model/2` returns error for filtered-out models
3. `Registry.list_providers/0` only includes allowed providers
4. Custom providers from config appear in Registry

**test/mix/tasks/model_sync_test.exs**:
1. Mix task respects catalog filters when writing files
2. ValidProviders module only includes allowed providers
3. `--ignore-config` flag bypasses filters

### Fixture Tests

Update existing coverage tests to handle catalog filtering:
1. When mode: `:allowlist`, only run fixtures for allowed models
2. Document how to add new models (add to allow list first)

## Migration Path

### Breaking Change Notice

**This is a breaking change**:
- The Catalog system requires an explicit `allow` configuration
- Without configuration, the application will raise an error at boot
- Existing applications must add catalog configuration before upgrading

### Migration Steps

#### Step 1: Before upgrading, create allowlist
Add to `config/config.exs` (or appropriate environment config):
```elixir
config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini gpt-3.5-turbo),
    anthropic: ~w(claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022),
    # ... list all models you currently use
  }
```

**Tip**: Check your test fixtures in `test/coverage/fixtures/` to see which models you're currently testing.

#### Step 2: Update ReqLLM
```bash
mix deps.update req_llm
```

#### Step 3: Re-sync models (optional)
```bash
mix req_llm.model_sync
```

This refreshes the base metadata from models.dev. Note that `priv/models_dev/*.json` now contains raw, unfiltered metadata.

#### Step 4: Verify
```elixir
# In IEx
ReqLLM.Provider.Registry.list_providers()
# => [:openai, :anthropic]

ReqLLM.Provider.Registry.get_model("openai:gpt-4o")
# => {:ok, model}

ReqLLM.Provider.Registry.get_model("openai:gpt-4-turbo")
# => {:error, :model_not_found}  # Not in allowlist
```

#### Step 5: Migrate local patches (if you had them)
If you were using `priv/models_local/*.json` patches:
1. Move provider-level patches to `config.overrides.providers`
2. Move model-level patches to `config.overrides.models`
3. Move custom providers to `config.custom`
4. Delete `priv/models_local/` directory

### Adding New Models

When models.dev adds a new model:

1. Run `mix req_llm.model_sync` (downloads latest metadata)
2. New model is **not** loaded (because not in allowlist)
3. Test the new model manually if needed
4. Add to allowlist in config:
   ```elixir
   allow: %{
     openai: ~w(gpt-4o gpt-4o-mini gpt-5-turbo)  # Added gpt-5-turbo
   }
   ```
5. Restart application (catalog loads at boot)
6. Add fixtures: `mix mc "openai:gpt-5-turbo" --record`



## Open Questions & Future Enhancements

### Open Questions
1. Should we warn or raise when a model in the allowlist doesn't exist in the source metadata?
2. How to handle provider modules (DSL) vs. metadata-only providers when both define the same provider_id?
3. Should test environment bypass the empty allowlist check entirely?

### Future Enhancements
1. **Hot Reloading**: Watch config/priv files and reload catalog without restart
2. **Per-Environment Catalogs**: Different allow lists for dev/test/prod environments
3. **Catalog Validation Task**: `mix req_llm.catalog.validate` to check config syntax and unknown references
4. **Usage Analytics**: Track which allowed models are actually used vs. just available
5. **Model Aliases**: Define friendly aliases for long model IDs (e.g., `gpt4: "gpt-4o"`)
6. **Cost Budgets**: Set per-model or per-provider cost limits in config

## Performance Characteristics

### Compile-Time vs Runtime Trade-offs

**Compile-Time (Base Catalog)**:
- Parse and normalize all JSON files: ~50-200ms for typical catalog (20-40 providers)
- Happens once per compilation, embedded in BEAM bytecode
- Triggered by manifest changes (when `mix req_llm.model_sync` runs)

**Runtime (Application Start)**:
- Load compiled base: ~1ms (simple function call, no I/O)
- Apply configuration (allowlist, custom, overrides): ~5-10ms
- Total startup impact: **~10ms vs ~200ms** (20x faster)

**Memory**:
- Base catalog stored in BEAM constant pool (shared, immutable)
- Effective catalog stored in `:persistent_term` (fast reads, no copying)
- Minimal overhead compared to runtime-only approach

**Development Experience**:
- Running `mix req_llm.model_sync` triggers recompilation of `Catalog.Base` module
- Configuration changes (allowlist, overrides) do NOT require recompilation
- Clean separation: metadata changes vs configuration changes

## Effort Estimate

- **Compile-Time Base Module** (Phase 1): 1-2 hours
- **Runtime Catalog Module** (Phase 2): 2-3 hours
- **Model Sync Manifest** (Phase 3): 1 hour
- **Registry Integration** (Phase 4): 1 hour
- **Configuration Schema** (Phase 5): 1 hour
- **Testing**: 2-3 hours
- **Documentation**: 1 hour

**Total**: 9-13 hours (~1-1.5 days)

## Success Criteria

1. ✅ Application raises error at boot if catalog.allow is missing or empty (except in test)
2. ✅ Only explicitly allowed models are loaded - new models from models.dev do NOT appear
3. ✅ Can override metadata for specific providers/models via config
4. ✅ Can define custom local providers (VLLM, LLaMA CPP) via config
5. ✅ `mix req_llm.model_sync` only fetches and writes raw metadata (no filtering)
6. ✅ Registry API works with filtered catalog from Catalog.load()
7. ✅ All existing tests pass with catalog configuration added
8. ✅ New tests cover allowlist filtering, overrides, and custom providers
9. ✅ Clear migration guide for users with local JSON patches

## Summary

The Catalog system provides fine-grained control over model availability through a simple, configuration-driven approach. By introducing a single abstraction layer between raw metadata and the Provider Registry, we gain:

- **Explicit Control**: No models load unless explicitly allowed in config
- **Single Override Path**: Configuration is the only way to modify metadata (no file-based patches)
- **Extensibility**: Easy custom model definitions for local providers
- **Safety**: Prevents unexpected test failures from upstream changes
- **Clarity**: Clear separation between dev-time (model_sync) and runtime (Catalog)

The implementation is straightforward, well-scoped, and maintains ReqLLM's principle of simplicity while adding powerful new capabilities.
