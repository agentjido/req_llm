# ReqLLM Catalog System - Demo & Usage Guide

## Overview

The Catalog system provides fine-grained control over which AI models are available in ReqLLM through a configuration-driven approach. It supports allowlisting, custom providers, and metadata overrides.

## Running the Demo

```bash
mix run lib/examples/scripts/catalog_demo.exs
```

The demo demonstrates six key scenarios:

### 1. Base Catalog (Compile-Time)
Shows the raw catalog compiled from `priv/models_dev/*.json` at build time:
- 63 providers loaded
- Zero runtime I/O
- ~20x faster startup vs runtime parsing

### 2. Allowlist Filtering
Restricts available models to an explicit list:
```elixir
config :req_llm, :catalog,
  allow: %{
    openai: ["gpt-4o", "gpt-4o-mini"],
    anthropic: ["claude-3-5-sonnet-20241022"]
  }
```
Result: Only 2 providers, 3 models total (filtered from 1000+)

### 3. Custom Providers
Adds local inference servers (VLLM, LLaMA CPP):
```elixir
config :req_llm, :catalog,
  custom: [
    %{
      provider: %{
        id: "vllm",
        name: "vLLM Local",
        base_url: "http://localhost:8000",
        env: []
      },
      models: [
        %{id: "llama-3.2-3b-instruct", ...}
      ]
    }
  ]
```
Result: Custom providers work alongside cloud providers

### 4. Metadata Overrides
Corrects or updates upstream metadata:
```elixir
config :req_llm, :catalog,
  overrides: [
    providers: %{
      openai: %{"base_url" => "https://api.custom-proxy.com/v1"}
    },
    models: %{
      openai: %{
        "gpt-4o-mini" => %{
          "cost" => %{"input" => 0.0001, "output" => 0.0004}
        }
      }
    }
  ]
```
Result:
- OpenAI base_url changed from `https://api.openai.com/v1` → `https://api.custom-proxy.com/v1`
- GPT-4o-mini cost changed from $0.15/$0.60 → $0.0001/$0.0004 per M tokens

### 5. Full Pipeline
Combines all features (allowlist + custom + overrides):
- Filters to 3 specific models
- Adds local inference server
- Overrides context limits
Result: Complete control over available models and their metadata

### 6. Registry Integration
Shows how the catalog integrates with the Provider Registry:
```elixir
{:ok, catalog} = ReqLLM.Catalog.load(config)
:ok = ReqLLM.Provider.Registry.initialize(catalog)

# Registry API works with filtered catalog
ReqLLM.Provider.Registry.list_providers()
# => [:anthropic, :openai]

ReqLLM.Provider.Registry.get_model(:openai, "gpt-4o-mini")
# => {:ok, %ReqLLM.Model{...}}

ReqLLM.Provider.Registry.get_model(:openai, "gpt-4-turbo")
# => {:error, :model_not_found}  # Filtered out by allowlist
```

## Key Demonstrations

### Before/After Comparisons

**Base Catalog:**
- Providers: 63
- Models: 1000+
- Source: Compiled from JSON

**After Allowlist:**
- Providers: 2 (OpenAI, Anthropic)
- Models: 3 (only allowed models)
- Filtered: 99.7% of models removed

**After Overrides:**
- OpenAI base_url: Custom proxy
- GPT-4o-mini cost: Updated pricing
- Claude 3.5 Haiku cost: Custom pricing

### Registry Behavior

**With Catalog Filtering:**
```elixir
# Allowed model - succeeds
{:ok, model} = Registry.get_model(:openai, "gpt-4o-mini")
# => Returns model struct with metadata

# Filtered model - fails gracefully
{:error, :model_not_found} = Registry.get_model(:openai, "gpt-4-turbo")
# => Model exists in base but not in allowlist
```

## Configuration Examples

### Production Setup (Minimal)
```elixir
# config/prod.exs
config :req_llm, :catalog_enabled?, true

config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini),
    anthropic: ~w(claude-3-5-sonnet-20241022)
  }
```

### Development Setup (With Local Models)
```elixir
# config/dev.exs
config :req_llm, :catalog_enabled?, true

config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o-mini),
    vllm: ~w(llama-3.2-3b-instruct)
  },
  custom: [
    %{
      provider: %{id: :vllm, base_url: "http://localhost:8000", env: []},
      models: [%{id: "llama-3.2-3b-instruct", ...}]
    }
  ]
```

### Enterprise Setup (With Overrides)
```elixir
# config/prod.exs
config :req_llm, :catalog_enabled?, true

config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini),
    anthropic: ~w(claude-3-5-sonnet-20241022)
  },
  overrides: [
    providers: %{
      openai: %{"base_url" => "https://enterprise-proxy.company.com/openai"}
    },
    models: %{
      openai: %{
        "gpt-4o-mini" => %{"cost" => %{"input" => 0.0, "output" => 0.0}}  # Internal pricing
      }
    }
  ]
```

## Performance Characteristics

### Compile-Time (Base Catalog)
- **Parse time**: ~50-200ms for 1000+ models
- **Frequency**: Once per compilation
- **Storage**: BEAM constant pool (shared, immutable)

### Runtime (Application Start)
- **Load base**: ~1ms (function call)
- **Apply config**: ~5-10ms (filter, merge, override)
- **Total**: ~10ms vs ~200ms (20x improvement)

### Memory
- **Base catalog**: BEAM constant pool
- **Effective catalog**: `:persistent_term` (fast reads)
- **Overhead**: Minimal (~same as runtime-only)

## Testing

The demo includes comprehensive testing of all features:
- ✅ Base catalog loading
- ✅ Allowlist filtering
- ✅ Custom provider merging
- ✅ Metadata overrides
- ✅ Full pipeline integration
- ✅ Registry API compatibility

Run tests:
```bash
mix test test/req_llm/catalog_test.exs           # Catalog unit tests
mix test test/req_llm/catalog/base_test.exs      # Base catalog tests  
mix test test/req_llm/provider/registry_test.exs # Registry integration
```

## Migration from Current System

### Step 1: Add Configuration
```elixir
# config/config.exs
config :req_llm, :catalog_enabled?, false  # Start disabled

config :req_llm, :catalog,
  allow: %{},
  overrides: [],
  custom: []
```

### Step 2: Enable Catalog
```elixir
config :req_llm, :catalog_enabled?, true

config :req_llm, :catalog,
  allow: %{
    openai: ~w(gpt-4o gpt-4o-mini),
    anthropic: ~w(claude-3-5-sonnet-20241022)
    # ... list all models you use
  }
```

### Step 3: Verify
```bash
mix test  # All tests should pass
```

## Troubleshooting

### Empty Allowlist Error
```
** (ReqLLM.Error.Config) catalog.allow cannot be empty
```
**Solution**: Add models to allowlist or use test environment (allows empty)

### Model Not Found After Adding to Allowlist
**Check**:
1. Model ID matches exactly (case-sensitive)
2. Provider ID is correct
3. Model exists in base catalog: `ReqLLM.Catalog.Base.base()["provider"]["models"]`

### Override Not Applied
**Common issues**:
1. Keys must be strings (not atoms) in override maps
2. Overrides applied after filtering - ensure model is in allowlist
3. Deep merge - only specified fields are changed, others preserved

## Next Steps

1. Review [CATALOG.md](CATALOG.md) for complete design documentation
2. Run the demo script to see features in action
3. Configure your allowlist based on actual usage
4. Add custom providers for local inference
5. Apply overrides for enterprise deployments

## Summary

The demo shows that the Catalog system successfully:
- ✅ Loads base catalog at compile-time (zero runtime I/O)
- ✅ Filters models by allowlist (explicit control)
- ✅ Supports custom providers (local inference)
- ✅ Applies metadata overrides (enterprise flexibility)
- ✅ Integrates with Registry API (backward compatible)
- ✅ Maintains 20x startup performance improvement
