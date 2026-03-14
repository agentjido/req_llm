# Model Metadata

LLMDB is the model registry behind ReqLLM. Browse the current catalog on [LLMDB.xyz](https://llmdb.xyz).

This guide is about shared registry metadata. If you only need to call a model that is not in the registry yet, start with the [Model Specs](model-specs.md) guide. You do not need a local patch just to make a request.

## Overview

The model metadata system provides:
- **Automatic metadata** via the `llm_db` dependency, sourced from models.dev
- **Browsable catalog** via [LLMDB.xyz](https://llmdb.xyz)
- **Local patch system** for adding missing models or overriding metadata
- **Explicit model-spec path** for using models before they land in the registry
- **Seamless integration** with no provider configuration changes needed
- **Persistent customizations** that survive dependency updates

## Model Metadata Flow

### 1. Upstream Metadata via llm_db

Model metadata is provided by the `llm_db` dependency, which sources data from the models.dev API. This includes:
- Model capabilities (text generation, embedding, vision, etc.)
- Pricing information (input/output token costs)
- Context limits and output limits
- Supported modalities (text, images, audio)
- Provider-specific details

To get the latest model metadata, update the dependency:

```bash
mix deps.update llm_db
```

If the model is still missing after that, use the [Model Specs](model-specs.md) path first. Add or patch registry metadata only when you want the model to be shared, discoverable, and available to tooling like `mix mc`.

### 2. Local Patch Integration

ReqLLM automatically discovers and merges local patches from `priv/models_local/` on top of the `llm_db` data.

Use this when you want missing models to behave like first-class registry entries for the whole codebase, not when you just need to make one request.

## File Structure

```
priv/
├── models_dev/         # Auto-generated from models.dev (DO NOT EDIT)
│   ├── openai.json
│   ├── anthropic.json
│   └── ...
└── models_local/       # Local patches and extensions
    ├── openai_patch.json
    ├── custom_models.json
    └── ...
```

## Creating Local Patches

### Basic Patch Structure

Patch files use the same JSON structure as upstream metadata:

```json
{
  "provider": {
    "id": "openai",
    "name": "OpenAI", 
    "base_url": "https://api.openai.com/v1",
    "env": ["OPENAI_API_KEY"],
    "doc": "AI model provider"
  },
  "models": [
    {
      "id": "text-embedding-3-small",
      "name": "Text Embedding 3 Small",
      "provider": "openai",
      "provider_model_id": "text-embedding-3-small",
      "type": "embedding",
      "attachment": false,
      "open_weights": false,
      "reasoning": false,
      "temperature": false,
      "tool_call": false,
      "knowledge": "2024-01",
      "release_date": "2024-01-25",
      "cost": {
        "input": 0.00002,
        "output": 0.0
      },
      "limit": {
        "context": 8191,
        "output": 0
      },
      "modalities": {
        "input": ["text"],
        "output": ["embedding"]
      },
      "dimensions": {
        "min": 1,
        "max": 1536,
        "default": 1536
      }
    }
  ]
}
```

### Patch Merging Rules

- **New models**: Added to the provider's model list
- **Existing models**: Patch data overrides upstream data by model ID
- **Provider metadata**: Can be extended or overridden
- **Multiple patches**: All JSON files in `priv/models_local/` are processed

## Common Use Cases

### Adding Missing Models To The Shared Registry

Some models may not be available in the upstream registry yet:

```json
{
  "provider": {
    "id": "openai"
  },
  "models": [
    {
      "id": "gpt-4o-mini-2024-07-18",
      "name": "GPT-4o Mini (2024-07-18)",
      "provider": "openai",
      "provider_model_id": "gpt-4o-mini-2024-07-18",
      "type": "chat",
      "cost": {
        "input": 0.00015,
        "output": 0.0006
      }
    }
  ]
}
```

### Overriding Pricing

Adjust costs for enterprise pricing or different regions:

```json
{
  "provider": {
    "id": "openai"  
  },
  "models": [
    {
      "id": "gpt-4o",
      "cost": {
        "input": 0.002,
        "output": 0.008
      }
    }
  ]
}
```

### Adding Custom Models To The Shared Registry

Include private or custom model deployments:

```json
{
  "provider": {
    "id": "custom",
    "name": "Custom Provider",
    "base_url": "https://api.mycompany.com/v1",
    "env": ["CUSTOM_API_KEY"]
  },
  "models": [
    {
      "id": "company-llm-v1",
      "name": "Company LLM v1",
      "provider": "custom", 
      "type": "chat"
    }
  ]
}
```

## Working with Model Metadata

### Accessing Model Information

```elixir
# Get model details
{:ok, model} = ReqLLM.model("openai:gpt-4o")

# Check model capabilities  
model.capabilities.tool_call  # true
model.capabilities.reasoning  # false

# View pricing
model.cost.input   # 0.005
model.cost.output  # 0.015

# Context limits
model.max_tokens   # 4096 (output limit)
model.limit.context  # 128000 (input limit)
```

### Listing Available Models

```elixir
# All models for a provider
models = LLMDB.models(:openai)
specs = Enum.map(models, &LLMDB.Model.spec/1)
```

## Updating Model Metadata

Model metadata ships with the `llm_db` package dependency. To get the latest models, pricing, and capabilities:

```bash
mix deps.update llm_db
```





## Integration with Providers

The patch system works transparently with all ReqLLM providers. No code changes needed. Local patches in `priv/models_local/` are automatically integrated into the model registry at runtime.

This enables you to:
- Add missing models immediately without waiting for upstream updates
- Override metadata for your specific deployment requirements
- Include custom or private models alongside public ones
- Maintain local customizations across sync operations

If your only goal is to call a missing model right now, the [Model Specs](model-specs.md) guide is the simpler path.
