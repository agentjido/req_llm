You need a dedicated **ModelDB** layer with clear ingest → normalize → validate → enrich → index → publish stages, strong override precedence, and a fast in‑memory query API. Treat it as a standalone library that ReqLLM depends on.

---

## 1) Use cases to cover

**Sourcing and freshness**

* Pull upstream catalogs from `models.dev` on demand or via CI.
* Load local JSON patches and exclusions from the app.
* Register code‑level overrides for one‑off fixes or experiments.

**Normalization and identity**

* Normalize provider IDs (`google-vertex` → `:google_vertex`) and model IDs.
* Support aliases and model renames.
* Detect duplicates and resolve conflicts deterministically.

**Validation and schema evolution**

* Versioned schema for provider, model, limits, costs, and capabilities.
* Backward‑compatible migrations when upstream keys change.

**Capability semantics**

* Distinguish *feature* enablement from *transport* enablement.
  Example: tools supported but **tool streaming** not supported.
* Express nuance: native JSON vs tool‑schema, strictness, parallel tool calls, cached input pricing, etc.

**Allow/deny and scoping**

* Global allowlist and optional denylist, with globbing per provider.
* Per‑environment scoping (dev/test/prod) without code changes.

**Selection and fallback**

* Query by required capabilities; return best match with a fallback trace.
* Prefer providers per policy, then model family, then any allowed.

**Observability**

* Introspect *why* a field has a value and *from which source*.
* Hash/manifest for the published effective catalog.

**Hot reload**

* Refresh the effective catalog at runtime without recompilation.
* Keep queries lock‑free and fast.

---

## 2) Target architecture (standalone “ModelDB”)

**Layers**

1. **Sources**
   Behaviours for pulling raw provider+model blobs:

   * `:models_dev` HTTP JSON
   * `:file_glob` local `priv/models_local/*.json`
   * `:code` DSL‑based overrides

2. **Engine (ETL)**

   * Normalizes keys and IDs.
   * Validates against versioned schemas.
   * Applies precedence rules and merges.
   * Enriches with derived capabilities.
   * Compiles allow/deny into the effective set.

3. **Store**

   * Materialized, read‑only effective catalog in ETS with a version/epoch.
   * Persistent manifest on disk for compile‑time invalidation.

4. **Query API**

   * Filter by provider/model/capabilities.
   * Capability checks and selection with fallback.
   * Introspection of provenance (which source decided a field).

5. **Adapters**

   * Thin bridge so `ReqLLM.Provider.Registry` initializes from ModelDB, not from JSON files.

---

## 3) Data model (v2 schema)

### Provider (normalized)

```elixir
%ReqLLM.ModelDB.Provider{
  id: :openai,
  name: "OpenAI",
  base_url: "https://api.openai.com/v1" | nil,
  env: ["OPENAI_API_KEY"],
  doc: "…",
  extra: map()
}
```

### Model (normalized)

```elixir
%ReqLLM.ModelDB.Model{
  id: "gpt-4o-mini",
  provider: :openai,
  provider_model_id: "gpt-4o-mini",
  name: "GPT‑4o mini",
  family: "gpt-4o" | nil,
  release_date: ~D[2024-05-13] | nil,
  last_updated: ~D[2024-11-20] | nil,
  knowledge: ~D[2024-08-01] | ~D[2024-08-01] | nil,
  limits: %ReqLLM.ModelDB.Limits{context: 128_000, output: 4_096, rate_limit: %{…}} | nil,
  cost: %ReqLLM.ModelDB.Cost{
    input: float() | nil,
    output: float() | nil,
    cache_read: float() | nil,
    cache_write: float() | nil,
    training: float() | nil,
    image: float() | nil,
    audio: float() | nil
  } | nil,
  modalities: %{input: [:text | :image | :audio | :video | :document], output: [:text | :image | :audio | :video]} | nil,
  capabilities: %ReqLLM.ModelDB.Capabilities{
    chat: true | false,
    embeddings: true | false,
    reasoning: %{enabled: boolean(), token_budget: non_neg_integer() | nil},
    tools: %{enabled: boolean(), streaming: boolean(), strict: boolean(), parallel: boolean()},
    json: %{native: boolean(), schema: boolean(), strict: boolean()},
    streaming: %{text: boolean(), tool_calls: boolean()},
    attachments: %{input: [:image | :pdf | :docx | …], max_files: non_neg_integer() | nil}
  },
  tags: MapSet.t(String.t()),
  deprecated?: boolean(),
  aliases: [String.t()],
  extra: map()
}
```

**Notes**

* `capabilities` separates *feature* vs *transport* to encode “tools but no tool streaming”.
* `extra` retains unknown upstream keys for forward compatibility.

---

## 4) Source precedence and merge rules

**Precedence (highest → lowest)**

1. **Code overrides** (developer DSL, runtime or compile‑time)
2. **Local files** (patches and excludes)
3. **Upstream** (`models.dev` snapshot)

**Merge strategy**

* Maps: deep merge. Lists: de‑dup. Scalars: higher precedence wins.
* `:exclude` acts before merge (removes models by ID or glob).
* Field masking: allow a sentinel `:"__delete__"` to remove a field from lower sources.
* Provenance: for each field, record `{source, ts}` for diagnostics.

---

## 5) Allow/Deny configuration

Allow at provider level or with patterns:

```elixir
allow: %{
  anthropic: :all,
  openai: ["gpt-4*", "gpt-5", "o*"],
  groq: ["llama-3.3-70b-versatile"]
},
deny: %{
  openai: ["gpt-5-pro"]  # deny beats allow
}
```

* Compile patterns to regex once.
* Query path enforces allow/deny before returning models.

---

## 6) Enrichment rules

* Derive `family` from model ID (`gpt-4o-…` → `gpt-4o`).
* Fill `capabilities.json.schema/strict` for providers that advertise schema mode.
* Map provider quirks to capability flags:

  * Google JSON mode → `json.native: true, json.schema: true`
  * OpenAI strict tools → `json.schema: true, json.strict: true`
* Default `streaming.text` to `true` unless upstream says otherwise; default `streaming.tool_calls` to `false` unless proven true.
* Normalize dates to `Date` and money to per‑1M tokens.

---

## 7) Storage and publication

* **ETS table**: `:req_llm_modeldb` with snapshot struct `%ReqLLM.ModelDB.Snapshot{epoch, manifest_hash, providers: map(), models_by_provider: map(), indexes: map(), provenance: map()}`
* Reads are lock‑free. Replace the table atomically by swapping a reference in `persistent_term` or via an indirection pid that owns ETS.
* **Manifest file** in `priv/modeldb/.manifest.json` with file list + SHA256 of concatenated content. Use it for compile‑time invalidation.

---

## 8) Public API (ModelDB)

```elixir
# Entry points
ReqLLM.ModelDB.load(opts \\ []) :: {:ok, Snapshot.t()} | {:error, term()}
ReqLLM.ModelDB.reload() :: :ok
ReqLLM.ModelDB.snapshot() :: Snapshot.t()

# Read API
ReqLLM.ModelDB.get_provider(:anthropic) :: {:ok, Provider.t()} | :error
ReqLLM.ModelDB.list_providers(kind \\ :all) :: [:anthropic | :openai | ...]
ReqLLM.ModelDB.get_model(:openai, "gpt-4o") :: {:ok, Model.t()} | :error
ReqLLM.ModelDB.list_models(:openai, filters \\ []) :: [Model.t()]
ReqLLM.ModelDB.capabilities({:openai, "gpt-4o"}) :: Capabilities.t()
ReqLLM.ModelDB.allowed?({:openai, "gpt-4o"}) :: boolean()

# Selection and fallback
ReqLLM.ModelDB.select(
  require: [tools: true, streaming_tool_calls: false, json_native: true],
  prefer: [:openai, :anthropic],
  deny: [{"openai", "gpt-5-pro"}]
) :: {:ok, {:provider, atom(), model_id :: String.t()}, trace :: map()} | {:error, :no_match}

# Provenance
ReqLLM.ModelDB.provenance(:openai, "gpt-4o", [:capabilities, :cost]) :: map()
```

**Filters example**

```elixir
ReqLLM.ModelDB.list_models(:openai,
  require: [chat: true, tools: true],
  forbid: [streaming_tool_calls: true],
  modalities: [input: [:text], output: [:text]]
)
```

---

## 9) ReqLLM integration plan (file‑by‑file)

### A) New modules (all under `lib/req_llm/modeldb/`)

1. `modeldb/schema.ex`

   * Typed structs and NimbleOptions schemas for Provider, Model, Limits, Cost, Capabilities.
   * `@schema_version 2`

   ```elixir
   def validate(:provider, map) :: {:ok, Provider.t()} | {:error, term()}
   def validate(:model, map) :: {:ok, Model.t()} | {:error, term()}
   ```

2. `modeldb/source.ex` (behaviour)

   ```elixir
   @callback id() :: atom()
   @callback fetch(keyword()) :: {:ok, [map()]} | {:error, term()}
   ```

3. `modeldb/source/models_dev.ex`

   * Replace direct use of `Req.get/1` in `Mix.Tasks.*` with this module.
   * Parse remote JSON. Do no merging here, just emit normalized maps.

4. `modeldb/source/files.ex`

   * Load `priv/models_local/*.json` with support for `"models"` and `"exclude"`.
   * Return two sets: patches and exclusions.

5. `modeldb/source/code.ex`

   * DSL for code overrides:

     ```elixir
     use ReqLLM.ModelDB.DSL

     provider :openai, env: ["OPENAI_API_KEY"] do
       model "gpt-4o-mini", override tools: [streaming: false]
       exclude "o4-mini"
     end
     ```

6. `modeldb/merge.ex`

   * Implements precedence and deep merge with field provenance.

7. `modeldb/allowlist.ex`

   * Compiles `allow` and `deny` maps into regex matchers.
   * `allowed?(provider, model_id) :: boolean()`

8. `modeldb/enrich.ex`

   * Derive families, fill capability defaults, normalize costs and dates.

9. `modeldb/index.ex`

   * Build indexes: models_by_provider, provider_by_model, tags.

10. `modeldb/store.ex`

* ETS owner, snapshot struct, epoch handling, atomic swaps.

11. `modeldb/query.ex`

* User‑facing filter/search helpers and `select/2`.

12. `modeldb/dsl.ex`

* Macro to build code overrides into plain maps consumed by engine.

13. `modeldb/diagnostics.ex`

* Explain decisions and provenance, return manifest hash.

### B) Modify existing files

1. `lib/mix/tasks/model_sync.ex` → **retire** as the merge engine. Keep as a thin CLI:

   * Rename to `Mix.Tasks.Modeldb.Sync`.
   * Delegate to `ReqLLM.ModelDB.Source.ModelsDev.fetch/1` and write raw cache `priv/modeldb/models_dev/*.json`.
   * Write `.manifest.json` for compile‑time invalidation.
   * Remove local patch merging here. The engine does that at runtime.

   **Impact**: Removes ETL from the Mix task. Lowers coupling.
   **Exact edits**: Replace `execute_sync/1` with:

   ```elixir
   with {:ok, providers} <- ReqLLM.ModelDB.Source.ModelsDev.fetch(verbose: v),
        :ok <- Modeldb.Manifest.write(providers, dest_dir) do
     :ok
   end
   ```

2. `lib/req_llm/catalog/base.ex` → **deprecate**

   * Replace with a shim that reads `.manifest.json` only to mark external resources for recompiles.
   * Do not read provider files directly.

3. `lib/req_llm/catalog.ex` → **replace** with `ReqLLM.ModelDB` usage

   * `load/0` becomes:

     ```elixir
     def load, do: ReqLLM.ModelDB.load(from_config())
     ```
   * Delete custom merge and allowlist logic here; call ModelDB.

4. `lib/req_llm/model/metadata.ex`

   * Replace file IO with queries to `ReqLLM.ModelDB.Query`.
   * New API:

     ```elixir
     def load_full_metadata("openai:gpt-4o"), do:
       with {:ok, model} <- ModelDB.get_model(:openai, "gpt-4o"),
            do: {:ok, ModelDB.Schema.to_map(model)}
     ```
   * Keep `get_model_metadata/2` but delegate to ModelDB.

5. `lib/req_llm/metadata.ex`

   * Move provider/model schemas to `ModelDB.Schema`.
   * Keep only helper utilities used by the `ReqLLM.Model` struct, or make this a thin wrapper that calls ModelDB.

6. `lib/req_llm/model.ex`

   * When building from `"provider:model"`, resolve via `ModelDB.get_model/2`.
   * If missing, create a minimal struct, then `with_defaults/1`.
   * Ensure `with_metadata/1` pulls from ModelDB.

7. `lib/req_llm/capability.ex`

   * Use `ModelDB.capabilities/1`.
   * Update `supports_object_generation?/1` to inspect `capabilities.json` and `capabilities.tools`.

8. `lib/req_llm/provider/registry.ex`

   * Replace JSON‑only registration path with ModelDB snapshot.
   * On `initialize/0`:

     ```elixir
     snapshot = ReqLLM.ModelDB.snapshot()
     providers = snapshot.providers |> Map.keys()
     ```
   * `list_models/1` enumerates from snapshot indexes.
   * Remove `register_json_only_providers/1`.
   * Fix `parse_model_spec/1` to avoid `String.to_existing_atom/1`. Use `ModelDB.Query.parse_provider/1` that returns `{:ok, atom}` if known, otherwise `{:error, :unknown_provider}`. This avoids crashing on new providers.

9. Config files

   * `config/config.exs`:

     ```elixir
     config :req_llm, :modeldb,
       sources: [
         {:models_dev, refresh: :startup, url: "https://models.dev/api.json"},
         {:file_glob, path: "priv/models_local/*.json"},
         {:code, module: MyApp.ModelOverrides} # optional
       ],
       precedence: [:code, :file_glob, :models_dev],
       allow: %{…},   # move from catalog_allow.exs
       deny:  %{…},
       policy: [prefer: [:openai, :anthropic], fallback: [:same_provider, :same_family, :any]]
     ```
   * Migrate `config/catalog_allow.exs` → `config/modeldb_allow.exs` and include deny support.

10. Test helpers

* Update `ReqLLM.Test.ModelMatrix` to call `ModelDB` for allowed specs instead of `Catalog`.
* Replace `ReqLLM.Catalog.allowed_spec?/2` with `ModelDB.allowed?/1` and `ModelDB.list_models/2`.

---

## 10) Key interfaces and examples

**Selecting a model with fallback**

```elixir
{:ok, {provider, model_id}, trace} =
  ReqLLM.ModelDB.select(
    require: [tools: true, streaming_tool_calls: false, json_native: true],
    prefer: [:openai, :anthropic]
  )
# trace explains rejections and precedence decisions
```

**Checking nuanced capability**

```elixir
caps = ReqLLM.ModelDB.capabilities({:openai, "gpt-4o-mini"})
caps.tools.enabled          # true
caps.tools.streaming        # false  ← controls business logic
```

**Local overrides in code**

```elixir
defmodule MyApp.ModelOverrides do
  use ReqLLM.ModelDB.DSL

  provider :openai do
    model "gpt-4o-mini",
      override: [
        capabilities: [tools: [streaming: false], json: [strict: true]]
      ]
  end

  provider :cerebras do
    exclude "qwen-3-235b-a22b-thinking-*"
  end
end
```

**Local file patch format (unchanged, more explicit allowed)**

```json
{
  "provider": { "id": "openai", "env": ["OPENAI_API_KEY"] },
  "models": [
    {
      "id": "gpt-4o-mini",
      "capabilities": { "tools": { "enabled": true, "streaming": false } }
    }
  ]
}
```

**Deny example overriding allow**

```elixir
config :req_llm, :modeldb,
  allow: %{openai: ["gpt-4o*", "gpt-5*"]},
  deny:  %{openai: ["gpt-5-pro"]}
```

---

## 11) Side effects and impacts

* **Lower compile‑time coupling**: JSON parsing moves out of compile steps. Only the manifest is an external resource to trigger recompilation.
* **Safer provider parsing**: eliminate `String.to_existing_atom/1` crashes in `Registry.parse_model_spec/1`.
* **Faster reads**: ETS snapshot keeps queries O(1) and GC‑friendly. Swaps are atomic.
* **Clear precedence**: Source ordering becomes explicit and inspectable.
* **Better capability gating**: Business logic can safely key on `caps.tools.streaming` vs `caps.tools.enabled`.

---

## 12) Critical decisions

* **ETS vs persistent_term**: Use ETS for the catalog to allow frequent reloads; keep a small `persistent_term` for the current ETS table id or epoch only.
* **Schema versioning**: Introduce `@schema_version 2`. Add migrators for upstream changes.
* **Field provenance**: Store per‑field `{source, ts}` to debug frustrating mismatches.
* **Globbing**: Compile once at load. Deny overrides allow.
* **Sentinel deletes**: Support `:"__delete__"` in code/file patches to intentionally remove bad upstream fields.

---

## 13) Concrete refactor checklist

* [ ] Add `lib/req_llm/modeldb/*` modules listed above.
* [ ] Move config from `:catalog` to `:modeldb` with allow/deny/policy/sources.
* [ ] Replace `Catalog` and `Catalog.Base` with shims delegating to ModelDB.
* [ ] Update `Model.Metadata`, `Model`, `Capability`, and `Provider.Registry` to consume ModelDB.
* [ ] Replace `Mix.Tasks.ReqLlm.ModelSync` with `Mix.Tasks.Modeldb.Sync` that only mirrors upstream cache and writes manifest.
* [ ] Keep `priv/models_local` semantics; they now feed the engine as a source.
* [ ] Add diagnostics command `mix modeldb.explain <provider:model>` to print provenance.

---

## 14) Exact edits in current files

* **`lib/req_llm/provider/registry.ex`**

  * Replace `register_json_only_providers/1`, `load_json_metadata/2`, `atomize_json_keys/1` with reads from `ModelDB.snapshot()`.
  * Change `parse_model_spec/1` to use safe provider parsing:

    ```elixir
    defp parse_model_spec(model_spec) do
      with [p, m] <- String.split(model_spec, ":", parts: 2),
           {:ok, provider} <- ReqLLM.ModelDB.Query.parse_provider(p) do
        {:ok, provider, m}
      else
        _ -> {:error, "Unknown or invalid provider"}
      end
    end
    ```

* **`lib/req_llm/model/metadata.ex`**

  * In `load_full_metadata/1`: call `ModelDB.get_model/2` instead of `File.read`.
  * In `get_model_metadata/2`: `ModelDB.get_model(provider, model_name)`.

* **`lib/req_llm/capability.ex`**

  * In `supports_object_generation?/1`: inspect `caps.json.native || caps.tools.strict`.

* **`config/catalog_allow.exs` → `config/modeldb_allow.exs`**

  * Move `openai_models` etc. into `allow`.
  * Add `deny` entries for intentionally blocked models.
  * Update `config/config.exs` to use `:modeldb` key.

* **`lib/mix/tasks/model_sync.ex`**

  * Rename file and module to `Mix.Tasks.Modeldb.Sync`.
  * Strip merge logic; keep download and manifest write.

---

## 15) How this flows in ReqLLM

1. App boots. `ReqLLM.ModelDB.load(from_config())` builds the effective catalog from sources and writes to ETS, returns epoch and manifest hash.
2. `ReqLLM.Provider.Registry.initialize/0` enumerates providers and models from ModelDB, registering implemented providers and keeping metadata‑only providers visible.
3. Callers use `ReqLLM.Model.from/1`. It resolves via ModelDB, fills defaults, and validates caps before routing to a provider.
4. Your business logic uses `ReqLLM.Capability.supports?/2` and `ReqLLM.ModelDB.select/2` to gate features and pick fallbacks.

This design gives you a clean ETL pipeline, precise capability semantics, deterministic precedence, and fast queries, while preserving escape hatches for local overrides.
