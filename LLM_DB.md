# llm_db Integration Plan

## Overview

This document outlines the plan to integrate [llm_db](https://hex.pm/packages/llm_db) as a dependency to handle model metadata in req_llm. The llm_db package was extracted from req_llm because model metadata changes constantly and benefits from independent CalVer versioning.

**Key Principle:** Use llm_db for MODEL METADATA while keeping all PROVIDER IMPLEMENTATIONS in req_llm intact.

## Background

### What llm_db Provides
- **Build-time ETL** via `mix llm_db.pull` and `mix llm_db.build` to generate `snapshot.json`
- **Runtime loading** with `LLMDB.load/1` and `:persistent_term` storage
- **Rich data structures:** `LLMDB.Model` and `LLMDB.Provider` with capabilities, costs, limits, modalities
- **Capability-based selection** with `LLMDB.select/1` and `LLMDB.candidates/1`
- **Runtime filtering** and custom provider support
- **Multiple model spec formats** (colon `"provider:model"`, at `"model@provider"`, tuple `{:provider, "model"}`)

### What req_llm Currently Has (to be replaced/updated)
1. `mix req_llm.model_sync` task - fetches from models.dev and generates JSON files
2. `ReqLLM.Provider.Registry` - `:persistent_term` storage with DSL-based registration
3. `ReqLLM.Model` struct - simplified model config
4. `ReqLLM.Catalog.Base` - compile-time catalog from `priv/models_dev/*.json`
5. Provider implementations via DSL - each provider module registers itself

### What req_llm Must Keep
- **Provider behavior** definition and all callbacks
- **Provider implementations** (Anthropic, OpenAI, Google, etc.)
- **Provider-specific logic** (normalize_model_id, translate_options, streaming, etc.)
- **Existing public APIs** for backward compatibility

---

## Implementation Phases

### Phase 0: Add llm_db Without Breaking Anything
**Effort: <1 hour**

#### Steps

1. **Update mix.exs**
   ```elixir
   defp deps do
     [
       {:req, "~> 0.5"},
       {:jason, "~> 1.4"},
       {:llm_db, "~> 2025.1"}, # Add this - CalVer versioning
       # ... existing deps
     ]
   end
   ```

2. **Add configuration**
   ```elixir
   # config/config.exs
   config :req_llm,
     metadata_source: :legacy,  # Feature flag: :legacy | :llm_db
     llm_db_snapshot: nil       # nil = use packaged snapshot
   ```

3. **Update Application.start/2**
   ```elixir
   def start(_type, _args) do
     # Try to load llm_db snapshot
     snapshot = Application.get_env(:req_llm, :llm_db_snapshot, :default)
     case LLMDB.load(snapshot) do
       {:ok, _} -> 
         Logger.debug("LLMDB loaded successfully")
       {:error, reason} -> 
         Logger.warning("LLMDB not loaded (#{inspect(reason)}). Using legacy metadata.")
     end
     
     # ... rest of existing startup
   end
   ```

#### Success Criteria
- [x] llm_db dependency added
- [x] Configuration flags in place
- [x] LLMDB loads at startup (or gracefully falls back)
- [x] All existing tests pass unchanged

---

### Phase 1: Create Adapter Layer
**Effort: 1-3 hours**

#### Steps

1. **Create `ReqLLM.Metadata.LLMDBAdapter`**
   
   Location: `lib/req_llm/metadata/llmdb_adapter.ex`
   
   ```elixir
   defmodule ReqLLM.Metadata.LLMDBAdapter do
     @moduledoc """
     Adapter layer between llm_db and req_llm's metadata needs.
     
     Provides a unified interface for accessing model metadata regardless
     of whether the source is llm_db or the legacy system.
     """
     
     @doc "List all provider IDs"
     @spec provider_ids() :: [atom()]
     def provider_ids do
       LLMDB.providers()
       |> Enum.map(& &1.id)
     end
     
     @doc "Get provider struct from llm_db"
     @spec get_provider(atom()) :: {:ok, LLMDB.Provider.t()} | {:error, term()}
     def get_provider(provider_id) do
       case LLMDB.provider(provider_id) do
         nil -> {:error, :provider_not_found}
         provider -> {:ok, provider}
       end
     end
     
     @doc "Get model struct from llm_db"
     @spec get_model(atom(), String.t()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
     def get_model(provider_id, model_name) do
       case LLMDB.model(provider_id, model_name) do
         nil -> {:error, :model_not_found}
         model -> {:ok, model}
       end
     end
     
     @doc "List models for a provider"
     @spec list_models(atom()) :: {:ok, [String.t()]} | {:error, term()}
     def list_models(provider_id) do
       case LLMDB.models(provider_id) do
         [] -> {:error, :provider_not_found}
         models -> {:ok, Enum.map(models, & &1.id)}
       end
     end
     
     @doc "Get environment variable key for provider"
     @spec env_key(atom()) :: String.t() | nil
     def env_key(provider_id) do
       case get_provider(provider_id) do
         {:ok, provider} -> List.first(provider.env)
         _ -> nil
       end
     end
     
     @doc "Convert llm_db model to ReqLLM.Model"
     @spec to_req_llm_model(LLMDB.Model.t()) :: ReqLLM.Model.t()
     def to_req_llm_model(%LLMDB.Model{} = m) do
       limit = %{
         context: m.limits.context,
         output: m.limits.output
       }
       
       modalities = %{
         input: m.modalities.input,
         output: m.modalities.output
       }
       
       capabilities = %{
         reasoning: !!m.capabilities.reasoning.enabled,
         tool_call: !!(m.capabilities.tools.enabled),
         temperature: true, # Most models support temperature
         attachment: :image in m.modalities.input || :audio in m.modalities.input
       }
       
       cost = %{
         input: m.cost.input,
         output: m.cost.output
       }
       |> maybe_put(:cached_input, m.cost.cache_read)
       
       ReqLLM.Model.new(m.provider, m.id,
         limit: limit,
         modalities: modalities,
         capabilities: capabilities,
         cost: cost
       )
       |> Map.put(:_metadata, to_map(m))
     end
     
     # Helper to convert llm_db model to raw map for _metadata
     defp to_map(%LLMDB.Model{} = model) do
       Map.from_struct(model)
     end
     
     defp maybe_put(map, _key, nil), do: map
     defp maybe_put(map, key, value), do: Map.put(map, key, value)
   end
   ```

2. **Create metadata source selector**
   
   Location: `lib/req_llm/metadata.ex`
   
   ```elixir
   defmodule ReqLLM.Metadata do
     @moduledoc """
     Metadata access layer with pluggable sources.
     """
     
     @doc "Get configured metadata source"
     @spec source() :: :legacy | :llm_db
     def source do
       Application.get_env(:req_llm, :metadata_source, :legacy)
     end
     
     # ... keep existing helper functions
   end
   ```

#### Success Criteria
- [x] Adapter module created with all required functions
- [x] Metadata source selector function implemented
- [x] Unit tests for adapter conversion functions
- [x] All existing tests still pass

---

### Phase 2: Rewire Provider.Registry
**Effort: 1-3 hours**

#### Steps

1. **Simplify registry storage**
   
   Registry now only needs to store provider module bindings:
   ```elixir
   # Old format (everything in persistent_term):
   %{
     provider_id => %{
       module: Module,
       metadata: %{models: [...], ...}
     }
   }
   
   # New format (metadata from llm_db):
   %{
     provider_id => %{module: Module}
   }
   ```

2. **Update `get_model/2`**
   
   ```elixir
   def get_model(provider_id, model_name) when is_atom(provider_id) do
     case get_provider(provider_id) do
       {:ok, provider_module} ->
         # Normalize model ID if provider implements it
         normalized_name =
           if function_exported?(provider_module, :normalize_model_id, 1) do
             provider_module.normalize_model_id(model_name)
           else
             model_name
           end
         
         case ReqLLM.Metadata.source() do
           :llm_db ->
             with {:ok, llm_model} <- ReqLLM.Metadata.LLMDBAdapter.get_model(provider_id, normalized_name) do
               {:ok, ReqLLM.Metadata.LLMDBAdapter.to_req_llm_model(llm_model)}
             else
               _ -> {:error, :model_not_found}
             end
           
           :legacy ->
             # Keep existing implementation
             legacy_get_model(provider_id, normalized_name)
         end
       
       _ ->
         {:error, :provider_not_found}
     end
   end
   ```

3. **Update other registry functions**
   
   Update these to use llm_db when configured:
   - `list_providers/0`
   - `list_models/1`
   - `model_exists?/1`
   - `get_env_key/1`
   - `get_provider_metadata/1`

4. **Update `register/3` to warn about ignored metadata**
   
   ```elixir
   def register(provider_id, module, metadata) do
     if ReqLLM.Metadata.source() == :llm_db && metadata && metadata != %{} do
       Logger.warning("Provider metadata ignored when using llm_db source. " <>
                      "Use llm_db custom providers instead.")
     end
     
     # Store only module binding
     current = get_registry()
     updated = Map.put(current, provider_id, %{module: module})
     :persistent_term.put(@registry_key, updated)
     :ok
   end
   ```

#### Success Criteria
- [x] Registry storage simplified
- [x] `get_model/2` uses llm_db when configured
- [x] All registry functions work with both sources
- [x] Tests pass for both `:legacy` and `:llm_db` modes

---

### Phase 3: Update ReqLLM.Model
**Effort: <1 hour**

#### Steps

1. **Update `from/1` to be lenient**
   
   Keep existing behavior but don't fail if model not found in registry:
   ```elixir
   def from(provider_model_string) when is_binary(provider_model_string) do
     case String.split(provider_model_string, ":", parts: 2) do
       [provider_str, model_name] when provider_str != "" and model_name != "" ->
         case ReqLLM.Metadata.parse_provider(provider_str) do
           {:ok, provider} ->
             # Don't require model to exist in registry - create minimal struct
             {:ok, new(provider, model_name)}
           
           {:error, reason} ->
             {:error, ReqLLM.Error.validation_error(:invalid_provider, reason)}
         end
       
       _ ->
         {:error, ReqLLM.Error.validation_error(:invalid_model_spec, "Expected 'provider:model'")}
     end
   end
   ```

2. **Update `with_metadata/1`**
   
   ```elixir
   def with_metadata(model_spec) when is_binary(model_spec) do
     with {:ok, base_model} <- from(model_spec) do
       case ReqLLM.Metadata.source() do
         :llm_db ->
           case ReqLLM.Metadata.LLMDBAdapter.get_model(base_model.provider, base_model.model) do
             {:ok, llm_model} ->
               {:ok, ReqLLM.Metadata.LLMDBAdapter.to_req_llm_model(llm_model)}
             error ->
               error
           end
         
         :legacy ->
           # Keep existing implementation
           legacy_with_metadata(model_spec)
       end
     end
   end
   ```

#### Success Criteria
- [x] `from/1` continues to work as before
- [x] `with_metadata/1` uses llm_db when configured
- [x] All Model tests pass in both modes

---

### Phase 4: Deprecate model_sync Task
**Effort: <1 hour**

#### Steps

1. **Update `mix req_llm.model_sync`**
   
   ```elixir
   defmodule Mix.Tasks.ReqLlm.ModelSync do
     use Mix.Task
     
     @shortdoc "DEPRECATED - Use mix llm_db.pull && mix llm_db.build"
     
     @moduledoc """
     [DEPRECATED] This task is deprecated in favor of llm_db's build tasks.
     
     ## Migration
     
     Instead of:
         mix req_llm.model_sync
     
     Use:
         mix llm_db.pull
         mix llm_db.build
     
     Or configure llm_db sources in config.exs and rely on the packaged snapshot.
     """
     
     def run(args) do
       Mix.shell().info("""
       [DEPRECATED] mix req_llm.model_sync is deprecated.
       
       Use llm_db's build tasks instead:
         mix llm_db.pull   # Fetch latest model data
         mix llm_db.build  # Generate snapshot
       
       Running delegated tasks...
       """)
       
       # Delegate to llm_db for backward compatibility
       Mix.Task.run("llm_db.pull", args)
       Mix.Task.run("llm_db.build", args)
     end
   end
   ```

2. **Update documentation**
   
   - Update README to show llm_db workflow
   - Add migration guide
   - Update AGENTS.md with new commands

#### Success Criteria
- [x] Task shows deprecation notice
- [x] Task still works via delegation
- [x] Documentation updated

---

### Phase 5: Replace Compile-Time Catalog
**Effort: <1 hour**

#### Steps

1. **Simplify or remove `ReqLLM.Catalog.Base`**
   
   Option A: Remove entirely if llm_db snapshot handles all needs
   
   Option B: Keep as recompile trigger:
   ```elixir
   defmodule ReqLLM.Catalog.Base do
     @moduledoc """
     Compile-time trigger for llm_db snapshot changes.
     
     This module ensures the project recompiles when the llm_db
     snapshot is updated.
     """
     
     @snapshot_path Application.app_dir(:llm_db, "priv/llm_db/snapshot.json")
     @external_resource @snapshot_path
     
     def snapshot_path, do: @snapshot_path
   end
   ```

2. **Remove catalog loading from Application**
   
   The catalog initialization code in `ReqLLM.Application` can be simplified since LLMDB handles loading.

#### Success Criteria
- [x] Compile-time catalog dependency removed or simplified
- [x] Application startup cleaner
- [x] No performance regression

---

### Phase 6: Update Tests
**Effort: 1-3 hours**

#### Steps

1. **Create test helper**
   
   Location: `test/support/llmdb_helper.ex`
   
   ```elixir
   defmodule ReqLLM.Test.LLMDBHelper do
     @moduledoc """
     Test helpers for llm_db integration.
     """
     
     @test_snapshot "test/fixtures/llmdb_snapshot.json"
     
     def load_test_snapshot do
       case LLMDB.load(@test_snapshot) do
         {:ok, _} -> :ok
         {:error, reason} ->
           raise "Failed to load test snapshot: #{inspect(reason)}"
       end
     end
   end
   ```

2. **Create minimal test snapshot**
   
   Location: `test/fixtures/llmdb_snapshot.json`
   
   Create a minimal snapshot with a few test models for each provider.

3. **Update test setup**
   
   ```elixir
   # test/test_helper.exs
   
   # Load test snapshot for llm_db mode tests
   if Application.get_env(:req_llm, :metadata_source) == :llm_db do
     ReqLLM.Test.LLMDBHelper.load_test_snapshot()
   end
   
   ExUnit.start()
   ```

4. **Update tests that reference files**
   
   Replace assertions on `priv/models_dev/*.json` with assertions on Registry/Model API calls.

5. **Add CI matrix for both modes**
   
   Run tests with both `:legacy` and `:llm_db` metadata sources.

#### Success Criteria
- [x] Test snapshot created
- [x] Tests pass with `:llm_db` mode
- [x] Tests pass with `:legacy` mode
- [x] CI runs both configurations

---

### Phase 7: Flip Default and Clean Up
**Effort: <1 hour (when ready)**

#### Steps

1. **Change default configuration**
   
   ```elixir
   # config/config.exs
   config :req_llm,
     metadata_source: :llm_db  # Changed from :legacy
   ```

2. **Mark legacy code paths as deprecated**
   
   Add `@deprecated` tags to legacy functions:
   ```elixir
   @deprecated "Use llm_db-based metadata access"
   defp legacy_get_model(provider_id, model_name) do
     # ...
   end
   ```

3. **Update CHANGELOG**
   
   Document the migration and breaking changes.

4. **Plan future removal**
   
   Schedule legacy code removal for next major version.

#### Success Criteria
- [x] Default switched to llm_db
- [x] Legacy code marked deprecated
- [x] All tests passing
- [x] Documentation complete

---

## Data Structure Mappings

### llm_db → ReqLLM.Model

| llm_db Field | ReqLLM.Model Field | Notes |
|--------------|-------------------|-------|
| `provider` (atom) | `provider` (atom) | Direct mapping |
| `id` (string) | `model` (string) | Model identifier |
| `limits.context` | `limit.context` | Context window size |
| `limits.output` | `limit.output` | Max output tokens |
| `modalities.input` | `modalities.input` | List of atoms |
| `modalities.output` | `modalities.output` | List of atoms |
| `capabilities.reasoning.enabled` | `capabilities.reasoning` | Boolean |
| `capabilities.tools.enabled` | `capabilities.tool_call` | Boolean |
| N/A | `capabilities.temperature` | Default `true` |
| `modalities.input` (check for :image/:audio) | `capabilities.attachment` | Derived |
| `cost.input` | `cost.input` | Per 1M tokens |
| `cost.output` | `cost.output` | Per 1M tokens |
| `cost.cache_read` | `cost.cached_input` | Optional |
| (entire struct) | `_metadata` | Raw map for BC |

### Example Conversion

```elixir
# llm_db Model
%LLMDB.Model{
  id: "gpt-4o-mini",
  provider: :openai,
  limits: %{context: 128_000, output: 16_384},
  modalities: %{input: [:text, :image], output: [:text]},
  capabilities: %{
    reasoning: %{enabled: false},
    tools: %{enabled: true, streaming: true}
  },
  cost: %{input: 0.15, output: 0.60, cache_read: 0.075}
}

# Converts to ReqLLM.Model
%ReqLLM.Model{
  provider: :openai,
  model: "gpt-4o-mini",
  max_tokens: nil,
  max_retries: 3,
  limit: %{context: 128_000, output: 16_384},
  modalities: %{input: [:text, :image], output: [:text]},
  capabilities: %{
    reasoning: false,
    tool_call: true,
    temperature: true,
    attachment: true
  },
  cost: %{input: 0.15, output: 0.60, cached_input: 0.075},
  _metadata: %{...}
}
```

---

## What Stays Unchanged

- ✅ `ReqLLM.Provider` behavior and all callbacks
- ✅ Provider implementation modules (Anthropic, OpenAI, Google, etc.)
- ✅ Provider-specific logic:
  - `normalize_model_id/1`
  - `default_env_key/0`
  - `translate_options/3`
  - `decode_stream_event/2,3`
  - `attach_stream/4`
  - etc.
- ✅ `ReqLLM.Model` struct definition
- ✅ Public API surface of `Provider.Registry`
- ✅ High-level APIs (`generate_text/3`, `stream_text/3`, etc.)

---

## Risks and Mitigations

### Risk: Snapshot not loaded at runtime
**Impact:** Model lookups fail
**Mitigation:**
- Load on application start with clear error messages
- Provide fallback to legacy during migration period
- Document snapshot location and loading in README

### Risk: Capability/cost/limits key mismatches
**Impact:** Wrong metadata returned to users
**Mitigation:**
- Centralize mapping in adapter with comprehensive unit tests
- Keep `_metadata` field for raw access
- Test against fixture models with known values

### Risk: Provider DSL metadata ignored
**Impact:** Custom metadata lost
**Mitigation:**
- Warn when metadata provided in DSL
- Document migration to llm_db custom providers
- Keep `default_env_key/0` callback functional

### Risk: Tests tied to file structure
**Impact:** Tests break when files removed
**Mitigation:**
- Replace file assertions with API assertions
- Provide test snapshot fixture
- Update tests incrementally per phase

---

## Future Enhancements (Optional)

### Advanced Capability Selection
Expose `ReqLLM.select/1` that delegates to `LLMDB.select/1`:

```elixir
# Select cheapest model with vision and 128k+ context
{:ok, {provider, model_id}} = ReqLLM.select(
  require: [
    json_native: true,
    tools: true,
    streaming_text: true
  ],
  forbid: [deprecated: true],
  prefer: [:openai, :anthropic],
  scope: :all
)
```

### Hot Reload Support
Add runtime snapshot reload without restart:

```elixir
# Reload snapshot from updated file
ReqLLM.reload_metadata()
```

### Custom Provider Overlays
Allow providers to inject metadata overlays at runtime:

```elixir
# In provider module
def metadata_overlay do
  %{
    models: %{
      "custom-model-1" => %{
        capabilities: %{tools: %{enabled: true}},
        limits: %{context: 8192}
      }
    }
  }
end
```

---

## Success Metrics

- ✅ All tests pass in both `:legacy` and `:llm_db` modes
- ✅ No public API changes (backward compatible)
- ✅ Documentation complete with migration guide
- ✅ CI validates both metadata sources
- ✅ Performance equivalent or better (persistent_term lookups)
- ✅ Model metadata stays current via llm_db CalVer updates

---

## Effort Summary

| Phase | Effort | Description |
|-------|--------|-------------|
| Phase 0 | <1h | Add dependency without breaking anything |
| Phase 1 | 1-3h | Create adapter layer |
| Phase 2 | 1-3h | Rewire Provider.Registry |
| Phase 3 | <1h | Update ReqLLM.Model |
| Phase 4 | <1h | Deprecate model_sync task |
| Phase 5 | <1h | Replace compile-time catalog |
| Phase 6 | 1-3h | Update tests |
| Phase 7 | <1h | Flip default and clean up |
| **Total** | **6-12h** | Full integration |

---

## References

- [llm_db on Hex](https://hex.pm/packages/llm_db)
- [llm_db on GitHub](https://github.com/agentjido/llm_db)
- [req_llm GitHub](https://github.com/agentjido/req_llm)
