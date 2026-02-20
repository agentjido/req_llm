# Model Metadata

ReqLLM maintains a comprehensive registry of AI models from various providers, automatically synchronized from the [models.dev](https://models.dev) API with support for local patches and overrides.

## Overview

The model metadata system provides:
- **Automatic metadata** via the `llm_db` dependency, sourced from models.dev
- **Local patch system** for adding missing models or overriding metadata
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

### 2. Local Patch Integration

ReqLLM automatically discovers and merges local patches from `priv/models_local/` on top of the `llm_db` data. No additional commands or configuration needed!

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

### Adding Missing Models

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

### Adding Custom Models

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
{:ok, model} = ReqLLM.Model.from("openai:gpt-4o")

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
models = ReqLLM.Model.list_for_provider(:openai)

# Filter by capability
embedding_models = ReqLLM.Model.list_for_provider(:openai)
|> Enum.filter(&(&1._metadata["type"] == "embedding"))

# Filter by cost
affordable_models = ReqLLM.Model.list_for_provider(:openai)
|> Enum.filter(&(&1.cost.input < 0.001))
```

## Updating Model Metadata

Model metadata ships with the `llm_db` package dependency. To get the latest models, pricing, and capabilities:

```bash
mix deps.update llm_db
```





## Integration with Providers

The patch system works transparently with all ReqLLM providers. No code changes needed - local patches in `priv/models_local/` are automatically integrated into the model registry at runtime.

This enables you to:
- Add missing models immediately without waiting for upstream updates
- Override metadata for your specific deployment requirements
- Include custom or private models alongside public ones
- Maintain local customizations across sync operations
