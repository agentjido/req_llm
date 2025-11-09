# llm_db Forced Integration Plan (Breaking Changes)

## Overview

This plan ignores backward compatibility to achieve the smoothest possible integration between `llm_db` and `req_llm`. Since both packages are authored by you and `llm_db` is unreleased, we can make changes to both sides for optimal integration.

**Target Version:** ReqLLM v1.1.0 (minor bump with breaking changes notification)

---

## Gap Analysis: LLMDB.Model vs ReqLLM.Model

### Current ReqLLM.Model Fields

```elixir
%ReqLLM.Model{
  # Required
  provider: atom(),          # :openai, :anthropic
  model: String.t(),         # "gpt-4o-mini"
  
  # Runtime control (req_llm specific)
  max_tokens: non_neg_integer() | nil,
  max_retries: non_neg_integer() | nil,  # Default: 3
  
  # Metadata (from llm_db or legacy)
  limit: %{context: int, output: int} | nil,
  modalities: %{input: [atom], output: [atom]} | nil,
  capabilities: %{reasoning: bool, tool_call: bool, temperature: bool, attachment: bool} | nil,
  cost: %{input: float, output: float, cached_input?: float} | nil,
  _metadata: map() | nil
}
```

### Current LLMDB.Model Fields

```elixir
%LLMDB.Model{
  # Required
  id: String.t(),            # "gpt-4o-mini"
  provider: atom(),          # :openai
  
  # Optional metadata
  name: String.t() | nil,
  family: String.t() | nil,
  
  # Limits
  limits: %{
    context: non_neg_integer() | nil,
    output: non_neg_integer() | nil
  },
  
  # Cost per 1M tokens
  cost: %{
    input: float() | nil,
    output: float() | nil,
    cache_read: float() | nil,
    cache_write: float() | nil,
    reasoning: float() | nil,
    image: float() | nil,
    audio: float() | nil
  },
  
  # Capabilities (nested)
  capabilities: %{
    chat: boolean(),
    embeddings: boolean() | map(),
    reasoning: %{enabled: bool, token_budget: int | nil},
    tools: %{enabled: bool, streaming: bool, strict: bool, parallel: bool},
    json: %{native: bool, schema: bool, strict: bool},
    streaming: %{text: bool, tool_calls: bool}
  },
  
  # Modalities
  modalities: %{
    input: [atom()],   # [:text, :image, :audio, :video]
    output: [atom()]
  },
  
  # Other
  tags: [String.t()],
  deprecated: boolean(),
  aliases: [String.t()],
  extra: map()
}
```

---

## Key Gaps and Conflicts

### 1. Field Name Collision: `model` vs `id`
- **ReqLLM**: Uses `model` field for model identifier
- **LLMDB**: Uses `id` field for model identifier

**Impact:** HIGH - accessed in 20+ files throughout req_llm

### 2. Runtime Control Fields Missing in LLMDB
- **ReqLLM specific**: `max_tokens`, `max_retries`
- **Usage**: 
  - `max_tokens`: Extracted in `Provider.Options.extract_model_options/2` (line 442)
  - `max_retries`: Only used in Jason encoding, validation, and as hardcoded default (3)

**Impact:** LOW - `max_retries` is barely used, `max_tokens` is primarily option-driven

### 3. Capabilities Structure Mismatch
- **ReqLLM**: Flat `%{reasoning: bool, tool_call: bool, temperature: bool, attachment: bool}`
- **LLMDB**: Nested `%{reasoning: %{enabled: bool}, tools: %{enabled: bool}, ...}`

**Impact:** MEDIUM - accessed in capability checks and metadata access

### 4. Metadata Access Pattern
- **ReqLLM**: Uses `get_in(model, [Access.key(:_metadata, %{}), "key"])` pattern
- **LLMDB**: Structured fields directly accessible

**Impact:** LOW - can be replaced with direct field access

### 5. Cost Field Structure
- **ReqLLM**: Simple `%{input: float, output: float, cached_input?: float}`
- **LLMDB**: Comprehensive with many cost types

**Impact:** LOW - enhancement, backward compatible

---

## Breaking Changes Analysis

### Where Breaking Changes Cause Most Friction

#### 1. **Provider Implementations** (HIGH FRICTION)
All providers access `model.model` to build API requests:
- `OpenAI.ChatAPI:148`, `OpenAI.ResponsesAPI:129,320,324`, etc.
- `Anthropic:175,191`
- `Google:205,215,284,294,351,360,379-380,403`
- `AmazonBedrock:249-250,270,284,384,483,517,554,793`
- 15+ provider files total

**Solution:** Global find-replace `model.model` → `model.id`

#### 2. **Generation & Core** (MEDIUM FRICTION)
Core operations access `model.provider`:
- `Generation:76,151,238,343`
- `Context:512`
- `Keys:53`
- `Capability:61,190`

**Solution:** No change needed - both use `provider` field

#### 3. **Jason Encoding** (LOW FRICTION)
```elixir
@derive {Jason.Encoder, only: [:provider, :model, :max_tokens, :max_retries]}
```

**Solution:** Update to `only: [:provider, :id, :max_tokens, :max_retries]`

#### 4. **Validation** (LOW FRICTION)
```elixir
def valid?(%__MODULE__{provider: provider, model: model, max_retries: max_retries})
  when is_atom(provider) and is_binary(model) and model != "" ...
```

**Solution:** Change `model:` to `id:`

#### 5. **Tests** (MEDIUM FRICTION)
Tests construct models with `model: "..."` field name.

**Solution:** Mass find-replace in tests

---

## Recommended Solution: Align ReqLLM to LLMDB

### Why This Direction?

1. **LLMDB is unreleased** - can still change, but already has good structure
2. **ReqLLM is newer** - fewer external users to break
3. **LLMDB is more comprehensive** - better model of the domain
4. **Simpler long-term** - use LLMDB.Model directly, no conversion layer

### Changes to Make

#### A. Changes to LLMDB (Pre-Release)

**1. Add runtime control fields to LLMDB.Model**

```elixir
# lib/llm_db/model.ex

defmodule LLMDB.Model do
  use Zoi.Struct
  
  # ... existing fields ...
  
  # Runtime control fields (optional, for consumer use)
  field :max_tokens, :integer, required: false
  field :max_retries, :integer, default: 3
end
```

**Rationale:** These are consumer-level runtime controls, not metadata. But storing them on the model struct is convenient for req_llm's API.

**Alternative:** Keep these in req_llm wrapper functions, not on struct.

**2. Consider aliasing `model_id` field for clarity**

```elixir
# Add a virtual field or function
def model_id(%LLMDB.Model{id: id}), do: id
```

**Rationale:** Makes it clearer that `id` is the model identifier, not some generic ID.

---

#### B. Changes to ReqLLM

**1. Replace ReqLLM.Model with LLMDB.Model**

```elixir
# lib/req_llm.ex

# Instead of internal struct, use llm_db's
defmodule ReqLLM do
  @type model :: LLMDB.Model.t()
  
  # Alias for convenience
  alias LLMDB.Model
end
```

**2. Global field rename: `model.model` → `model.id`**

All provider implementations need this change:

```elixir
# Before
def encode_body(request, %{model: %{model: model_id}}) do
  %{model: model_id, ...}
end

# After  
def encode_body(request, %{model: %{id: model_id}}) do
  %{model: model_id, ...}
end
```

**Automation:** Can be done with global find-replace:
- Pattern: `model\.model`
- Replace: `model.id`
- Files: `lib/req_llm/providers/**/*.ex`

**3. Update model construction APIs**

```elixir
# Old API
ReqLLM.Model.new(:anthropic, "claude-3-sonnet", max_tokens: 1000)

# New API - keep same signature, different implementation
defmodule ReqLLM.Model do
  @moduledoc """
  Model construction helpers wrapping LLMDB.Model.
  """
  
  def new(provider, model_id, opts \\ []) do
    # Try to load from llm_db first
    case LLMDB.model(provider, model_id) do
      %LLMDB.Model{} = model ->
        # Merge runtime options
        struct(model,
          max_tokens: Keyword.get(opts, :max_tokens),
          max_retries: Keyword.get(opts, :max_retries, 3)
        )
      
      nil ->
        # Create minimal model if not in llm_db
        %LLMDB.Model{
          id: model_id,
          provider: provider,
          max_tokens: Keyword.get(opts, :max_tokens),
          max_retries: Keyword.get(opts, :max_retries, 3),
          # Minimal defaults
          limits: %{context: 128_000, output: 4_096},
          modalities: %{input: [:text], output: [:text]},
          capabilities: %{
            chat: true,
            tools: %{enabled: false},
            json: %{native: false},
            streaming: %{text: true}
          },
          cost: %{input: 0.0, output: 0.0}
        }
    end
  end
  
  def from("provider:model"), do: from({:provider, "model", []})
  def from({provider, model_id, opts}), do: {:ok, new(provider, model_id, opts)}
  def from(%LLMDB.Model{} = model), do: {:ok, model}
  
  # Add convenience accessors that match old patterns
  def provider(%LLMDB.Model{provider: p}), do: p
  def model_id(%LLMDB.Model{id: id}), do: id
  def model_name(%LLMDB.Model{id: id}), do: id  # Alias
end
```

**4. Update capabilities access pattern**

```elixir
# Before (flat structure)
model.capabilities.tool_call
model.capabilities.reasoning

# After (nested structure)
model.capabilities.tools.enabled
model.capabilities.reasoning.enabled
```

**Search and replace pattern:**
- `model.capabilities.tool_call` → `model.capabilities.tools.enabled`
- `model.capabilities.reasoning` → `model.capabilities.reasoning.enabled`

**5. Simplify metadata access**

```elixir
# Before
get_in(model, [Access.key(:_metadata, %{}), "supports_json_schema"])

# After - direct access with llm_db structured fields
model.capabilities.json.schema

# Or use extra field for provider-specific flags
model.extra["supports_json_schema"]
```

**6. Remove Provider.Registry (replace with LLMDB)**

```elixir
# Delete lib/req_llm/provider/registry.ex

# Provider lookup becomes:
defmodule ReqLLM.Provider do
  def get!(provider_id) do
    # Get module binding from simple registry
    case :persistent_term.get({:req_llm_provider, provider_id}, nil) do
      nil -> raise "Unknown provider: #{provider_id}"
      module -> module
    end
  end
  
  def register(provider_id, module) do
    :persistent_term.put({:req_llm_provider, provider_id}, module)
  end
end

# Model lookup becomes:
LLMDB.model(:openai, "gpt-4o")  # Direct llm_db call
```

**7. Delete legacy metadata modules**

Remove:
- `lib/req_llm/catalog/base.ex`
- `lib/req_llm/model/metadata.ex`
- `lib/req_llm/metadata.ex` (consolidate into LLMDB adapter if needed)

**8. Simplify Application startup**

```elixir
def start(_type, _args) do
  # Load llm_db snapshot
  LLMDB.load()
  
  # Register provider modules (no metadata needed)
  ReqLLM.Provider.register(:openai, ReqLLM.Providers.OpenAI)
  ReqLLM.Provider.register(:anthropic, ReqLLM.Providers.Anthropic)
  # ... etc
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

**9. Delete mix task**

Remove `lib/mix/tasks/model_sync.ex` entirely. Users run `mix llm_db.pull && mix llm_db.build`.

---

## Migration Steps (Detailed)

### Step 1: Update LLMDB (Pre-Release Changes)

1. Add runtime fields to LLMDB.Model:
   ```bash
   cd llm_db
   # Edit lib/llm_db/model.ex
   # Add: field :max_tokens, :integer, required: false
   # Add: field :max_retries, :integer, default: 3
   mix test
   ```

2. Consider adding model_id/1 helper or keep `id` as-is

3. Publish llm_db v2025.1.0 (or appropriate CalVer)

### Step 2: Update ReqLLM Dependencies

```elixir
# mix.exs
def deps do
  [
    {:llm_db, "~> 2025.1"},
    # ... rest
  ]
end
```

### Step 3: Global Refactor (Use Scripts)

**A. Field rename script**

```bash
# find_replace.sh

# Rename model.model to model.id in all providers
find lib/req_llm/providers -type f -name "*.ex" -exec sed -i '' 's/model\.model/model.id/g' {} \;

# Rename in other core files
find lib/req_llm -type f -name "*.ex" -exec sed -i '' 's/model\.model/model.id/g' {} \;

# Update tests
find test -type f -name "*.exs" -exec sed -i '' 's/model: "/id: "/g' {} \;
```

**B. Update Jason.Encoder**

```elixir
# lib/req_llm/model.ex (if keeping wrapper)
@derive {Jason.Encoder, only: [:provider, :id, :max_tokens, :max_retries]}
```

**C. Update capabilities access**

Manual review and update files that access:
- `model.capabilities.tool_call` → `model.capabilities.tools.enabled`
- `model.capabilities.reasoning` → `model.capabilities.reasoning.enabled`
- `model.capabilities.attachment` → derive from `model.modalities.input`

### Step 4: Replace Internal Structures

1. **Replace ReqLLM.Model module**
   - Keep as thin wrapper around LLMDB.Model
   - Provide construction helpers (`new/3`, `from/1`)
   - Delegate to LLMDB for everything else

2. **Delete Registry**
   - Replace with simple `:persistent_term` module binding
   - All metadata comes from LLMDB

3. **Delete Catalog**
   - Remove `Catalog.Base`
   - Remove manifest files
   - Update Application.start/2

4. **Delete model_sync task**
   - Remove entirely
   - Update docs to use `mix llm_db.pull && mix llm_db.build`

### Step 5: Update Tests

1. **Test fixtures**
   - Create `test/fixtures/llmdb_snapshot.json`
   - Load in `test/test_helper.exs`:
     ```elixir
     LLMDB.load("test/fixtures/llmdb_snapshot.json")
     ExUnit.start()
     ```

2. **Update test data**
   - Global replace `model: "x"` → `id: "x"` in test files
   - Update capability checks to use nested structure

3. **Remove file-based tests**
   - Delete tests that check `priv/models_dev/*.json`
   - Replace with API-level assertions

### Step 6: Update Documentation

1. **README**
   - Remove `mix req_llm.model_sync` references
   - Add llm_db usage section
   - Document model construction

2. **CHANGELOG**
   - Document breaking changes:
     - Model struct field renamed: `model` → `id`
     - Capabilities structure now nested
     - Metadata now from llm_db
     - Removed `mix req_llm.model_sync` task

3. **Migration Guide**
   ```markdown
   ## Migrating to v1.1.0
   
   ### Model field renamed
   ```diff
   - model.model
   + model.id
   ```
   
   ### Capabilities now nested
   ```diff
   - model.capabilities.tool_call
   + model.capabilities.tools.enabled
   ```
   
   ### Use llm_db for model updates
   ```bash
   # Old
   mix req_llm.model_sync
   
   # New
   mix llm_db.pull
   mix llm_db.build
   ```
   ```

### Step 7: Release

1. Bump version to `1.1.0`
2. Tag and publish with clear breaking change notes
3. Notify users (if any) about upgrade path

---

## Code Change Estimate

### Files to Modify (Core)

| Category | Files | Effort |
|----------|-------|--------|
| Provider implementations | ~20 files | 2-3h (mostly find-replace) |
| Core model/generation | ~5 files | 1-2h |
| Tests | ~30 files | 2-3h |
| Documentation | ~5 files | 1h |
| Deletion (registry, catalog, sync) | ~5 files | 30m |
| **Total** | **~65 files** | **6-9h** |

### Automation Opportunities

- Global find-replace: `model.model` → `model.id` (80% of changes)
- Test fixtures: Generate from llm_db snapshot
- Provider registration: Can be auto-discovered from modules

---

## Alternative: Keep Conversion Layer

If breaking changes are too risky, keep a thin wrapper:

```elixir
defmodule ReqLLM.Model do
  @moduledoc """
  Thin wrapper around LLMDB.Model with backward-compatible field names.
  """
  
  defstruct [
    :provider,
    :model,        # Maps to llm_db_model.id
    :max_tokens,
    :max_retries,
    :_llm_db_model # Internal: stores the real LLMDB.Model
  ]
  
  def new(provider, model_id, opts \\ []) do
    llm_db_model = LLMDB.model(provider, model_id) || create_minimal(provider, model_id, opts)
    
    %__MODULE__{
      provider: llm_db_model.provider,
      model: llm_db_model.id,
      max_tokens: Keyword.get(opts, :max_tokens),
      max_retries: Keyword.get(opts, :max_retries, 3),
      _llm_db_model: llm_db_model
    }
  end
  
  # Delegate capability checks to nested llm_db model
  def capabilities(%__MODULE__{_llm_db_model: m}) do
    %{
      reasoning: m.capabilities.reasoning.enabled,
      tool_call: m.capabilities.tools.enabled,
      temperature: true,
      attachment: :image in m.modalities.input or :audio in m.modalities.input
    }
  end
end
```

**Pros:**
- Zero breaking changes
- Gradual migration possible

**Cons:**
- Maintains complexity
- Double struct overhead
- Conversion logic forever

---

## Recommendation

**Go with the breaking change approach:**

1. ReqLLM is new enough that few users exist
2. Changes are mechanical (find-replace)
3. Cleaner long-term architecture
4. Version bump (1.1.0) with clear migration guide is sufficient
5. Both packages under your control

**Timeline:**
- Week 1: Update LLMDB, release
- Week 2: Refactor ReqLLM (6-9h work)
- Week 3: Test thoroughly
- Week 4: Release 1.1.0 with migration guide

**Risk Mitigation:**
- Provide example PR showing migration for a fictional consumer
- Offer to help any early adopters migrate
- Keep 1.0.x branch for critical fixes

---

## Summary of Changes

### LLMDB Changes (Minimal)
- ✅ Add `max_tokens` and `max_retries` fields (optional)
- ✅ Publish as stable CalVer release

### ReqLLM Changes (Breaking)
- ❌ Replace `model` field with `id` field (BREAKING)
- ❌ Flatten capabilities back or update all access sites (BREAKING)
- ✅ Replace internal Model struct with LLMDB.Model
- ✅ Delete Provider.Registry (replace with LLMDB queries)
- ✅ Delete Catalog.Base (use LLMDB snapshot)
- ✅ Delete model_sync task (use llm_db tasks)
- ✅ Simplify Application startup (just LLMDB.load())
- ✅ Update all tests to use LLMDB models

### Migration Impact
- **Code changes:** ~65 files (mostly mechanical)
- **API changes:** Model field rename, capabilities structure
- **User impact:** Low (package is new, clear migration guide)
- **Long-term benefit:** Simpler architecture, better metadata

---

## What We Keep

✅ All provider implementations and behavior
✅ Provider-specific callbacks (normalize_model_id, translate_options, etc.)
✅ Streaming infrastructure
✅ High-level APIs (generate_text, stream_text, etc.)
✅ Error handling and types
✅ Testing patterns (just update fixtures)

**The core of req_llm stays the same - only metadata layer changes.**
