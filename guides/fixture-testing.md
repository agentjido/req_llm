# Fixture Testing Guide

ReqLLM uses a comprehensive fixture-based testing system to ensure reliability across all supported models and providers. This guide explains how we validate "Supported Models" and the testing infrastructure.

## Overview

The testing system validates models through the `mix req_llm.model_compat` task, which runs capability-focused tests against models selected from the registry.

## The Model Compatibility Task

### Basic Usage

```bash
# Validate all models with passing fixtures (fastest)
mix req_llm.model_compat

# Alias
mix mc
```

This runs tests using cached fixtures - no API calls are made. It validates models that have previously passing test results stored in `priv/supported_models.json`.

### Validating Specific Models

```bash
# Validate all Anthropic models
mix mc anthropic

# Validate specific model
mix mc "openai:gpt-4o"

# Validate all models for a provider
mix mc "xai:*"

# List all available models from registry
mix mc --available
```

### Recording New Fixtures

To test against live APIs and (re)generate fixtures:

```bash
# Re-record fixtures for xAI models
mix mc "xai:*" --record

# Re-record all models (not recommended, expensive)
mix mc "*:*" --record
```

### Testing Model Subsets

```bash
# Test sample models per provider (uses config/config.exs sample list)
mix mc --sample

# Test specific provider samples
mix mc --sample anthropic
```

## Architecture

### Model Registry

Model metadata is provided by the `llm_db` dependency, which sources data from [models.dev](https://models.dev). No manual sync is needed.

Each model entry includes:
- Capabilities (`tool_call`, `reasoning`, `attachment`, `temperature`)
- Modalities (`input: [:text, :image]`, `output: [:text]`)
- Limits (`context`, `output` token limits)
- Costs (`input`, `output` per 1M tokens)
- API-specific metadata

### Fixture State

The `priv/supported_models.json` file tracks which models have passing fixtures. This file is auto-generated and should not be manually edited.

### Comprehensive Test Macro

Tests use the `ReqLLM.ProviderTest.Comprehensive` macro (in `test/support/provider_test/comprehensive.ex`), which generates up to 9 focused tests per model based on capabilities:

1. **Basic generate_text** (non-streaming) - All models
2. **Streaming** with system context + creative params - Models with streaming support
3. **Token limit constraints** - All models
4. **Usage metrics and cost calculations** - All models
5. **Tool calling - multi-tool selection** - Models with `:tool_call` capability
6. **Tool calling - no tool when inappropriate** - Models with `:tool_call` capability
7. **Object generation (non-streaming)** - Models with object generation support
8. **Object generation (streaming)** - Models with object generation support
9. **Reasoning/thinking tokens** - Models with `:reasoning` capability

### Test Organization

```
test/coverage/
├── anthropic/
│   └── comprehensive_test.exs
├── openai/
│   └── comprehensive_test.exs
├── google/
│   └── comprehensive_test.exs
└── ...
```

Each provider has a single comprehensive test file:

```elixir
defmodule ReqLLM.Coverage.Anthropic.ComprehensiveTest do
  use ReqLLM.ProviderTest.Comprehensive, provider: :anthropic
end
```

The macro automatically:
- Selects models from `ModelMatrix` based on provider and operation type
- Generates tests for each model based on capabilities
- Handles fixture recording and replay
- Tags tests with provider, model, and scenario

## How "Supported Models" is Defined

A model is considered "supported" when it:

1. **Has metadata** in `priv/models_dev/<provider>.json`
2. **Passes comprehensive tests** for its advertised capabilities
3. **Has fixture** evidence stored for validation

The count you see in documentation ("135+ models currently pass our comprehensive fixture-based test suite") comes from models in `priv/supported_models.json`.

## Semantic Tags

Tests use structured tags for precise filtering:

```elixir
@moduletag :coverage                     # All coverage tests
@moduletag provider: "anthropic"         # Provider filter
@describetag model: "claude-3-5-sonnet"  # Model filter (without provider prefix)
@tag scenario: :basic                    # Scenario filter
```

Run specific subsets:

```bash
# All coverage tests
mix test --only coverage

# Specific provider
mix test --only "provider:anthropic"

# Specific scenario
mix test --only "scenario:basic"
mix test --only "scenario:streaming"
mix test --only "scenario:tool_multi"

# Specific model
mix test --only "model:claude-3-5-haiku-20241022"

# Combine filters
mix test --only "provider:openai" --only "scenario:basic"
```

## Environment Variables

### Fixture Mode Control

```bash
# Use cached fixtures (default, no API calls)
mix mc

# Record new fixtures (makes live API calls)
REQ_LLM_FIXTURES_MODE=record mix mc
# OR
mix mc --record
```

### Model Selection

```bash
# Test all available models
REQ_LLM_MODELS="all" mix mc

# Test all models from a provider
REQ_LLM_MODELS="anthropic:*" mix mc

# Test specific models (comma-separated)
REQ_LLM_MODELS="openai:gpt-4o,anthropic:claude-3-5-sonnet" mix mc

# Sample N models per provider
REQ_LLM_SAMPLE=2 mix mc

# Exclude specific models
REQ_LLM_EXCLUDE="gpt-4o-mini,gpt-3.5-turbo" mix mc
```

### Debug Output

```bash
# Verbose fixture debugging
REQ_LLM_DEBUG=1 mix mc
```

## Fixture System Details

### Fixture Storage

Fixtures are stored next to test files:

```
test/coverage/<provider>/fixtures/
├── basic.json
├── streaming.json
├── token_limit.json
├── usage.json
├── tool_multi.json
├── no_tool.json
├── object_basic.json
├── object_streaming.json
└── reasoning_basic.json
```

### Fixture Format

Fixtures capture the complete API response:

```json
{
  "captured_at": "2025-01-15T10:30:00Z",
  "model_spec": "anthropic:claude-3-5-sonnet-20241022",
  "scenario": "basic",
  "result": {
    "ok": true,
    "response": {
      "id": "msg_123",
      "model": "claude-3-5-sonnet-20241022",
      "message": {...},
      "usage": {...}
    }
  }
}
```

### Parallel Execution

The fixture system supports parallel test execution:

- Tests run concurrently for speed
- State tracking skips models with passing fixtures
- Use `--record` or `--record-all` to regenerate

## Development Workflow

### Adding a New Provider

1. Implement provider module and metadata
2. Create test file using `Comprehensive` macro
3. Record initial fixtures:
   ```bash
   mix mc "<provider>:*" --record
   ```
4. Verify all tests pass:
   ```bash
   mix mc "<provider>"
   ```

### Updating Model Coverage

1. Update your deps to get the latest model metadata from `llm_db`:
   ```bash
   mix deps.update llm_db
   ```
2. Record fixtures for new models:
   ```bash
   mix mc "<provider>:new-model" --record
   ```
3. Validate updated coverage:
   ```bash
   mix mc "<provider>"
   ```

### Refreshing Fixtures

Periodically refresh fixtures to catch API changes:

```bash
# Refresh specific provider
mix mc "anthropic:*" --record

# Refresh specific capability
REQ_LLM_FIXTURES_MODE=record mix test --only "scenario:streaming"

# Refresh all (expensive, requires all API keys)
mix mc "*:*" --record
```

## Quality Commitments

We guarantee that all "supported models" (those counted in our documentation):

1. **Have passing fixtures** for basic functionality
2. **Are tested against live APIs** before fixture capture
3. **Pass capability-focused tests** for advertised features
4. **Are regularly refreshed** to catch provider-side changes

### What's Tested

For each supported model:

- ✅ Text generation (streaming and non-streaming)
- ✅ Token limits and truncation behavior
- ✅ Usage metrics and cost calculation
- ✅ Tool calling (if advertised)
- ✅ Object generation (if advertised)
- ✅ Reasoning tokens (if advertised)

### What's NOT Guaranteed

- Complex edge cases beyond basic capabilities
- Provider-specific features not in model metadata
- Real-time behavior (fixtures may be cached)
- Exact API response formats (providers may change)

## Troubleshooting

### Fixture Mismatch

If tests fail with fixture mismatches:

```bash
# Re-record the specific scenario
mix mc "provider:model" --record
```

### Missing API Key

Tests skip if API key is unavailable:

```bash
# Set in .env file
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
```

### Debugging Fixture Issues

Enable verbose output:

```bash
REQ_LLM_DEBUG=1 mix test --only "provider:anthropic" --only "scenario:basic"
```

## Best Practices

1. **Run locally before CI**: `mix mc` before committing
2. **Record incrementally**: Don't re-record all fixtures at once
3. **Use samples for development**: `mix mc --sample` for quick validation
4. **Keep fixtures fresh**: Refresh fixtures when providers update APIs
5. **Tag tests appropriately**: Use semantic tags for precise test selection

## Commands Reference

```bash
# Validation (using fixtures)
mix mc                          # All models with passing fixtures
mix mc anthropic                # All Anthropic models
mix mc "openai:gpt-4o"          # Specific model
mix mc --sample                 # Sample models per provider
mix mc --available              # List all registry models

# Recording (live API calls)
mix mc --record                 # Re-record passing models
mix mc "xai:*" --record         # Re-record xAI models
mix mc "<provider>:*" --record  # Re-record specific provider

# Environment variables
REQ_LLM_FIXTURES_MODE=record    # Force recording
REQ_LLM_MODELS="pattern"        # Model selection pattern
REQ_LLM_SAMPLE=N                # Sample N per provider
REQ_LLM_EXCLUDE="model1,model2" # Exclude models
REQ_LLM_DEBUG=1                 # Verbose output
```

## Summary

The fixture-based testing system provides:

- **Fast local validation** with cached fixtures
- **Comprehensive coverage** across capabilities
- **Parallel execution** for speed
- **Clear model support guarantees** backed by test evidence
- **Easy provider addition** with minimal boilerplate

This system is how ReqLLM backs up the claim of "135+ supported models" - each one has fixture evidence of passing comprehensive capability tests.
