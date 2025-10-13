# Testing Guide - ReqLLM

Three-tier testing architecture for reliability and comprehensive coverage.

## Test Tiers

### Tier 1: Core Tests (`test/req_llm/`)
**NO API CALLS** - Pure unit tests with mocks
- Model parsing, schema compilation, error handling, provider registry

### Tier 2: Provider Tests (`test/providers/`)
**NO API CALLS** - Mocked provider behavior testing
- Parameter translation, response parsing, codec implementations
- Example: OpenAI max_tokens → max_completion_tokens for o1 models

### Tier 3: Coverage Tests (`test/coverage/`)
**FIXTURE-BASED API CALLS** - High-level integration testing
- Only test high-level API (`ReqLLM.generate_text/3`, `ReqLLM.stream_text/3`, etc.)
- Fixtures replayed by default, re-recorded with `REQ_LLM_FIXTURES_MODE=record`
- Uses shared provider test macros (`ReqLLM.ProviderTest.Core`, `ReqLLM.ProviderTest.Streaming`)

## Test Commands

### Path-Based Testing (Intentional)
```bash
# Core package tests only (fast)
mix test test/req_llm/

# Provider mocked tests only  
mix test test/providers/

# Coverage tests only
mix test test/coverage/
```

### Tag-Based Testing
```bash
# All coverage tests globally
mix test --only coverage

# By provider
mix test --only "provider:anthropic"
mix test --only "provider:openai"

# By scenario (test type)
mix test --only "scenario:basic"
mix test --only "scenario:streaming"
mix test --only "scenario:usage"
mix test --only "scenario:tool_multi"

# By model (without provider prefix)
mix test --only "model:claude-3-5-haiku-20241022"
mix test --only "model:gpt-4o-mini"

# Combine filters for precise targeting
mix test --only "provider:anthropic" --only "scenario:basic"
mix test --only "model:claude-3-5-haiku-20241022" --only "scenario:streaming"
```

### Fixture Recording (Live API Testing)
```bash
# Re-record all fixtures
REQ_LLM_FIXTURES_MODE=record mix test

# Re-record specific provider fixtures
REQ_LLM_FIXTURES_MODE=record mix test --only "provider:anthropic"

# Re-record specific scenario
REQ_LLM_FIXTURES_MODE=record mix test --only "scenario:basic"
REQ_LLM_FIXTURES_MODE=record mix test --only "scenario:streaming"

# Re-record for specific models only
REQ_LLM_FIXTURES_MODE=record REQ_LLM_MODELS="anthropic:claude-3-5-haiku-20241022" mix test --only "provider:anthropic"

# Re-record specific model + scenario combination
REQ_LLM_FIXTURES_MODE=record mix test --only "model:claude-3-5-haiku-20241022" --only "scenario:basic"
```

## Fixture System

Coverage tests use shared provider test macros with automatic fixture handling:

```elixir
defmodule ReqLLM.Coverage.Anthropic.CoreTest do
  @moduledoc """
  Core Anthropic API feature coverage tests.
  
  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """
  
  use ReqLLM.ProviderTest.Core, provider: :anthropic
end

defmodule ReqLLM.Coverage.Anthropic.StreamingTest do
  @moduledoc """
  Anthropic streaming API feature coverage tests.
  
  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """
  
  use ReqLLM.ProviderTest.Streaming, provider: :anthropic
end
```

The macros automatically:
- Generate tests for all models selected by `ModelMatrix` for the provider
- Handle fixture creation and replay transparently
- Support both streaming and non-streaming APIs

## Environment Variables

### Test Configuration
- `REQ_LLM_FIXTURES_MODE` - Controls fixture behavior (default: `replay`)
  - `record` - Record new fixtures from live API calls
  - `replay` - Use cached fixtures (default, no API calls)

### Model Selection
- `REQ_LLM_MODELS` - Model selection pattern (default: from config)
  - `"all"` - All available models
  - `"anthropic:*"` - All models from a provider
  - `"openai:gpt-4o,anthropic:claude-3-5-sonnet"` - Specific models (comma-separated)
- `REQ_LLM_SAMPLE` - Number of models to sample per provider
- `REQ_LLM_EXCLUDE` - Models to exclude (space or comma separated)
- `REQ_LLM_INCLUDE_RESPONSES` - Include OpenAI o1/o3/o4 models (default: excluded)
  - These models require `/v1/responses` endpoint which is not yet implemented
  - Set to `1` or `true` to include them (will fail until endpoint is supported)

### Examples
```bash
# Test only haiku model
REQ_LLM_MODELS="anthropic:claude-3-5-haiku-20241022" mix test --only "provider:anthropic"

# Test all OpenAI models
REQ_LLM_MODELS="openai:*" mix test --only "provider:openai"

# Sample 1 model per provider
REQ_LLM_SAMPLE=1 mix test --only coverage
```

## Semantic Tags

Tests are organized by Provider → Model → Scenario hierarchy.

**Tag Dimensions:**
- `provider` - `:anthropic`, `:openai`, `:google`, `:groq`, `:openrouter`, `:xai`
- `model` - Model identifier without provider prefix (e.g., `claude-3-5-haiku-20241022`, `gpt-4o-mini`)
- `scenario` - Test scenario type:
  - `:basic` - Basic generate_text (non-streaming)
  - `:streaming` - Streaming with system context
  - `:token_limit` - Token limit constraints
  - `:usage` - Usage metrics and costs
  - `:tool_multi` - Tool calling with multiple tools
  - `:tool_none` - Tool avoidance
  - `:object_basic` - Object generation (non-streaming)
  - `:object_streaming` - Object generation (streaming)
  - `:reasoning` - Reasoning/thinking tokens
- `coverage` - Mark coverage tests with `coverage: true`

## HTTP Mocking

- Custom mocks use `Req.Test.stub(:global, &mock_function/1)` when needed
