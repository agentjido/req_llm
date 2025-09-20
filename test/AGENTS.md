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
- Only test high-level API (`ReqLLM.generate_text/3`, etc.)
- Fixtures cached by default, regenerated with `LIVE=true`

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

# By category
mix test --only "category:core"
mix test --only "category:streaming"

# By provider
mix test --only "provider:anthropic"
mix test --only "provider:openai"
```

### Live API Testing
```bash
# Regenerate all fixtures
LIVE=true mix test

# Regenerate specific provider
LIVE=true mix test --only "provider:anthropic"

# Regenerate specific category
LIVE=true mix test --only "category:core"
```

## Fixture System

Coverage tests use `ReqLLM.Test.LiveFixture`:

```elixir
defmodule ReqLLM.Coverage.Anthropic.CoreTest do
  use ReqLLM.Test.LiveFixture, provider: :anthropic
  use ExUnit.Case, async: true

  @moduletag category: :core, provider: :anthropic, coverage: true

  test "basic text generation" do
    {:ok, response} = use_fixture(:provider, "basic-text", fn ->
      ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello!")
    end)
    
    assert is_binary(response.text)
  end
end
```

## Semantic Tags

**Tag Dimensions:**
- `category` - `:core`, `:streaming`, `:tools`, `:embedding`
- `provider` - `:anthropic`, `:openai`, `:google`, `:groq`, `:openrouter`, `:xai`
- `coverage` - Mark coverage tests with `coverage: true`

## HTTP Mocking

- Custom mocks use `Req.Test.stub(:global, &mock_function/1)` when needed
