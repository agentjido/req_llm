# Mix Tasks Guide

ReqLLM provides powerful Mix tasks for text generation, model coverage validation, and model synchronization. This guide covers all available tasks, their options, and common workflows.

## Overview

ReqLLM includes three main Mix tasks:

| Task | Alias | Purpose |
|------|-------|---------|
| `mix req_llm.gen` | `mix llm` | Generate text/objects from the command line |
| `mix req_llm.model_compat` | `mix mc` | Validate model coverage with fixtures |
| `mix req_llm.model_sync` | `mix ms` | Sync model metadata from models.dev |

## mix req_llm.gen

Generate text or structured objects from any AI model with unified interface. Useful for testing, experimentation, and quick one-off generations.

### Basic Usage

```bash
# Basic text generation
mix req_llm.gen "Explain how neural networks work"

# Streaming text
mix req_llm.gen "Write a story about space" --stream

# Generate JSON object
mix req_llm.gen "Create a user profile for John Smith, age 30" --json

# Specify model
mix req_llm.gen "Hello!" --model anthropic:claude-3-5-sonnet
```

### Options

| Option | Alias | Default | Description |
|--------|-------|---------|-------------|
| `--model` | `-m` | Config or `openai:gpt-4o-mini` | Model specification (provider:model) |
| `--stream` | `-s` | `true` | Stream the response token-by-token |
| `--json` | `-j` | `false` | Generate structured JSON object |
| `--temperature` | `-t` | Model default | Sampling temperature (0.0-2.0) |
| `--log-level` | `-l` | `info` | Log verbosity: `debug`, `info`, `warning` |

### Examples

#### Basic Text

```bash
# Simple question
mix req_llm.gen "What is 2+2?"

# Multi-word prompt
mix req_llm.gen "Explain quantum computing in simple terms"

# With specific model
mix req_llm.gen "Write a haiku" --model anthropic:claude-3-5-sonnet
```

#### Streaming

```bash
# Stream basic text
mix req_llm.gen "Tell me a joke" --stream

# Stream with model selection
mix req_llm.gen "Explain recursion" \
  --model openai:gpt-4o \
  --stream

# Stream creative content
mix req_llm.gen "Write a short story about AI" \
  --stream \
  --temperature 0.9
```

#### JSON Generation

```bash
# Generate structured object
mix req_llm.gen "Create a profile for Jane Doe, software engineer" --json

# With specific model
mix req_llm.gen "Generate user data for Bob Smith" \
  --model anthropic:claude-3-sonnet \
  --json \
  --temperature 0.1

# Stream JSON generation
mix req_llm.gen "Generate a product listing" \
  --json --stream \
  --log-level debug
```

#### Log Levels

```bash
# Quiet (only show generated content)
mix req_llm.gen "What is 2+2?" --log-level warning

# Normal (show model info and content) - default
mix req_llm.gen "Hello!" --log-level info

# Verbose (show timing and usage stats)
mix req_llm.gen "Explain AI" --log-level debug
```

### Built-in JSON Schema

When using `--json`, a default "person" schema is used:

```json
{
  "name": "string (required) - Full name of the person",
  "age": "integer - Age in years",
  "occupation": "string - Job or profession",
  "location": "string - City or region where they live"
}
```

### Output Examples

#### Text Generation

```
openai:gpt-4o → "What is 2+2?"

4

250ms • 15→3 tokens • ~$0.000090
```

#### Streaming

```
anthropic:claude-3-5-sonnet → "Write a haiku about coding"

Code flows like water,
Logic blooms in silent thought,
Debug reveals truth.

850ms • 28→45 tokens • ~$0.000420
```

#### JSON Generation

```
Generating object from openai:gpt-4o-mini
Prompt: Create a user profile for John Smith, age 30

{
  "name": "John Smith",
  "age": 30,
  "occupation": "Software Engineer",
  "location": "San Francisco, CA"
}
```

### Configuration

Set default model in `config/config.exs`:

```elixir
config :req_llm, default_model: "openai:gpt-4o-mini"
```

### Environment Variables

API keys are required for each provider:

```bash
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export GOOGLE_API_KEY=...
export OPENROUTER_API_KEY=...
export XAI_API_KEY=...
```

### Error Handling

```bash
# Missing API key
$ mix req_llm.gen "Hello" --model anthropic:claude-3-sonnet
Error: API key not found for anthropic

Please set your API key using one of these methods:
  1. Environment variable: export ANTHROPIC_API_KEY=your-api-key
  2. Application config: config :req_llm, anthropic_api_key: "your-api-key"
  3. Pass directly: generate_text(model, prompt, api_key: "your-api-key")

# Invalid model
$ mix req_llm.gen "Hello" --model openai:gpt-invalid
Error: Invalid model specification 'openai:gpt-invalid'

Available openai models:
  • openai:gpt-4o
  • openai:gpt-4o-mini
  • openai:gpt-3.5-turbo
```

## mix req_llm.model_compat (mix mc)

Validate ReqLLM model coverage using fixture-based testing. This task is how ReqLLM ensures all "supported models" actually work.

### What It Does

- Runs comprehensive tests against models from the registry
- Validates capabilities (streaming, tool calling, object generation, etc.)
- Uses cached fixtures for fast validation (no API calls by default)
- Records live API responses when `--record` flag is used
- Tracks validation state in `priv/supported_models.json`

### Basic Usage

```bash
# Show models with passing fixtures
mix req_llm.model_compat
mix mc

# List all models from registry
mix mc --available

# Test sample models
mix mc --sample
```

### Testing Specific Models

```bash
# Test all Anthropic models
mix mc anthropic
mix mc "anthropic:*"

# Test specific model
mix mc "openai:gpt-4o"

# Test all models from all providers
mix mc "*:*"

# Test by prefix
mix mc "openai:gpt-4*"
```

### Testing by Operation Type

```bash
# Text generation models only (default)
mix mc "google:*" --type text

# Embedding models only
mix mc "openai:*" --type embedding

# Both text and embedding
mix mc "google:*" --type all
```

### Recording Fixtures

**Important**: Recording makes live API calls and requires API keys.

```bash
# Re-record fixtures for specific provider
mix mc "xai:*" --record

# Re-record specific model
mix mc "openai:gpt-4o" --record

# Force re-record all (ignores existing state)
mix mc "*:*" --record-all
```

### Sample Testing

```bash
# Test sample subset (uses config/config.exs)
mix mc --sample

# Test sample for specific provider
mix mc "anthropic:*" --sample

# Configure samples in config/config.exs
config :req_llm,
  sample_text_models: [
    "openai:gpt-4o-mini",
    "anthropic:claude-3-5-haiku-20241022"
  ],
  sample_embedding_models: [
    "openai:text-embedding-3-small"
  ]
```

### Flags

| Flag | Description |
|------|-------------|
| `--available` | List all models from registry (no filtering) |
| `--sample` | Test sample subset from config |
| `--type TYPE` | Filter by operation: `text`, `embedding`, or `all` |
| `--record` | Re-record fixtures (live API calls) |
| `--record-all` | Force re-record all fixtures (ignores state) |
| `--debug` | Enable verbose fixture debugging output |

### Environment Variables

```bash
# Set fixture mode
REQ_LLM_FIXTURES_MODE=record mix mc

# Select specific models
REQ_LLM_MODELS="anthropic:*" mix mc

# Set operation type
REQ_LLM_OPERATION=embedding mix mc

# Enable debug output
REQ_LLM_DEBUG=1 mix mc

# Include full API responses
REQ_LLM_INCLUDE_RESPONSES=1 mix mc
```

### How Validation Works

The task validates models through comprehensive capability-focused tests:

1. **Basic generate_text** (non-streaming) - All models
2. **Streaming** with system context + creative params
3. **Token limit constraints**
4. **Usage metrics and cost calculations**
5. **Tool calling** - Multi-tool selection and refusal
6. **Object generation** (streaming and non-streaming)
7. **Reasoning/thinking tokens** (GPT-5, Claude)

Each test that passes creates a fixture file in `test/support/fixtures/<provider>/<model>/`.

### Fixture State Tracking

The `priv/supported_models.json` file tracks validation status:

```json
{
  "anthropic:claude-3-5-sonnet-20241022": {
    "status": "pass",
    "last_checked": "2025-01-29T10:30:00Z"
  },
  "openai:gpt-4o": {
    "status": "pass",
    "last_checked": "2025-01-29T10:30:15Z"
  },
  "xai:grok-vision-beta": {
    "status": "excluded",
    "last_checked": null
  }
}
```

### Example Output

```
----------------------------------------------------
Model Coverage Status
----------------------------------------------------

Anthropic
  ✓ claude-3-5-sonnet-20241022 (flagship)
  ✓ claude-3-5-haiku-20241022 (fast)
  ✗ claude-3-opus-20240229 (flagship)
  2 pass, 1 fail, 0 excluded, 0 untested | 66.7% coverage

OpenAI
  ✓ gpt-4o (flagship)
  ✓ gpt-4o-mini (fast)
  ✓ gpt-3.5-turbo (fast)
  3 pass, 0 fail, 0 excluded, 0 untested | 100.0% coverage

Overall Coverage: 5/6 models validated (83.3%)
```

### Testing Workflow

#### Adding a New Provider

```bash
# 1. Implement provider module
# 2. Create test file using Comprehensive macro
# 3. Record initial fixtures
mix mc "newprovider:*" --record

# 4. Verify all tests pass
mix mc "newprovider"
```

#### Updating Model Coverage

```bash
# 1. Sync latest metadata
mix req_llm.model_sync

# 2. Record fixtures for new models
mix mc "openai:gpt-5-mini" --record

# 3. Validate updated coverage
mix mc openai
```

#### Refreshing Fixtures

```bash
# Refresh specific provider (checks for API changes)
mix mc "anthropic:*" --record

# Refresh all (expensive, requires all API keys)
mix mc "*:*" --record
```

See [Fixture Testing Guide](fixture-testing.md) for complete details.

## mix req_llm.model_sync

Synchronize AI model catalog and pricing data from the models.dev API. Essential for keeping model metadata, pricing, and capabilities up-to-date.

### What It Does

1. **Fetches** complete model catalog from models.dev API
2. **Processes** providers and extracts model data
3. **Merges** local patches from `priv/models_local/`
4. **Generates** JSON files for each provider
5. **Updates** ValidProviders module with available providers

### Basic Usage

```bash
# Sync all providers (quiet mode)
mix req_llm.model_sync

# Detailed output with progress
mix req_llm.model_sync --verbose
```

### Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--verbose` | `-v` | Show detailed progress and statistics |

### Output Structure

After running, files are created/updated in:

```
priv/models_dev/
├── anthropic.json         # Anthropic models (Claude, etc.)
├── openai.json            # OpenAI models (GPT-4, GPT-3.5, etc.)
├── google.json            # Google models (Gemini, etc.)
├── groq.json              # Groq models
├── xai.json               # xAI models (Grok, etc.)
├── openrouter.json        # OpenRouter proxy models
└── .catalog_manifest.json # Auto-generated manifest with hash

lib/req_llm/provider/generated/
└── valid_providers.ex     # Generated list of valid provider atoms
```

### Local Patches

Local customizations in `priv/models_local/*.json` are automatically merged during sync. This allows you to:

- Add missing models not yet in models.dev
- Override pricing for enterprise agreements
- Include custom or private model deployments
- Exclude specific models from testing

#### Adding Models

Create a patch file in `priv/models_local/openai_patch.json`:

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

#### Excluding Models

To exclude models from validation:

```json
{
  "provider": {
    "id": "xai"
  },
  "exclude": [
    "grok-vision-beta"
  ]
}
```

### When to Run

- **After library updates**: Ensure model compatibility
- **New provider support**: When providers add new models
- **Regular maintenance**: Weekly or monthly for pricing updates
- **Before production**: Always sync before deploying

### Example Output

```
Syncing models for openai...
✓ Fetched 45 models from models.dev
✓ Found 1 patch file: priv/models_local/openai_patch.json  
✓ Merged 3 patch models
✓ Saved 48 models to priv/models_dev/openai.json
```

See [Model Metadata Guide](model-metadata.md) for more details on the metadata system.

## Common Workflows

### Initial Setup

```bash
# 1. Sync model metadata
mix req_llm.model_sync --verbose

# 2. Validate sample models
mix mc --sample

# 3. Test a quick generation
mix req_llm.gen "Hello, world!" --model openai:gpt-4o-mini
```

### Before Deploying

```bash
# 1. Sync latest models
mix req_llm.model_sync

# 2. Validate all models
mix mc "*:*"

# 3. Check coverage report
mix mc
```

### Adding a New Provider

```bash
# 1. Add models to local patch
cat > priv/models_local/newprovider.json <<EOF
{
  "provider": {
    "id": "newprovider",
    "name": "New Provider"
  },
  "models": [
    {
      "id": "model-v1",
      "name": "Model v1",
      "type": "chat"
    }
  ]
}
EOF

# 2. Sync to apply patch
mix req_llm.model_sync

# 3. Test the model
mix req_llm.gen "Hello" --model newprovider:model-v1

# 4. Record fixtures
mix mc "newprovider:*" --record
```

### Refreshing All Coverage

```bash
# Weekly maintenance workflow
mix req_llm.model_sync --verbose
mix mc --sample --record
mix mc
```

## Best Practices

1. **Run sync regularly**: Keep model metadata up-to-date
2. **Use samples for development**: Fast validation with `mix mc --sample`
3. **Record incrementally**: Don't re-record all fixtures at once
4. **Validate before commits**: Run `mix mc` before pushing code
5. **Keep patches organized**: One patch file per provider
6. **Test with real keys**: Set all provider API keys for full validation

## Troubleshooting

### Sync Issues

```bash
# Network error
Error: Failed to fetch models.dev data
# Check internet connection and API status

# Permission error
Error: Failed to write priv/models_dev/openai.json
# Ensure write access to priv/ directory
```

### Validation Issues

```bash
# Missing fixtures
mix mc anthropic
Skipping anthropic:claude-3-opus (not in registry)
# Run: mix req_llm.model_sync

# API key missing
Error: API key not found for anthropic
# Set: export ANTHROPIC_API_KEY=sk-ant-...

# Fixture mismatch
FAIL anthropic:claude-3-5-sonnet
# Re-record: mix mc "anthropic:claude-3-5-sonnet" --record
```

### Generation Issues

```bash
# Invalid model spec
Error: Unknown provider 'invalid'
# Check: mix mc --available

# Model not found
Error: Model 'gpt-invalid' not found
# List models: mix mc openai
```

## Related Guides

- [Model Metadata Guide](model-metadata.md) - Deep dive into model registry
- [Fixture Testing Guide](fixture-testing.md) - Complete testing documentation


## Summary

ReqLLM's Mix tasks provide a complete toolkit for:

- **Generating** text and objects from any supported model
- **Validating** model coverage with comprehensive fixture-based tests
- **Syncing** model metadata from models.dev with local customization

All tasks work together to ensure ReqLLM maintains high-quality support across 135+ models.
