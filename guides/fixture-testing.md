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

### GPT-6 Astra Launch Fixtures

Use `llm_db` 2026.9.1 or later to resolve `openai:gpt-6-astra`. CI runs the
standard Astra fixtures and focused feature fixtures in replay mode. The request tests in
`test/providers/openai_astra_test.exs` run without API calls:

```bash
mix test test/providers/openai_astra_test.exs
```

The [OpenAI Astra guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
lists these requirements as of 2026-09-03:

- Use Responses for tool calls.
- Use `low`, `medium`, `high`, `xhigh`, or `max` reasoning effort. `none` and
  `minimal` are not supported. The shared coverage tests use `low`.
- Omit `temperature`, `top_p`, `top_logprobs`, and
  `include: ["message.output_text.logprobs"]`.
- Use `prompt_cache_options: %{ttl: "30m"}` instead of `prompt_cache_retention`.

For WebSocket requests, `response.create` carries the request fields at the
top level. It does not wrap them in `response`. Omit `stream` and `background`.
See the [WebSocket event reference](https://developers.openai.com/api/reference/resources/responses/websocket-events).

Configure `OPENAI_API_KEY` in the environment or the local `.env` file. Start
with one recorded request:

```bash
mix mc "openai:gpt-6-astra" --scenario basic --record --max-concurrency 1
```

Check the result before recording more scenarios. A model access error does
not prove an API format change. After the basic request passes, record the
remaining standard scenarios:

```bash
mix mc "openai:gpt-6-astra" \
  --scenario streaming,usage,token_limit,context_append,tool_multi,tool_none,tool_round_trip,object_basic,object_streaming,reasoning \
  --record --max-concurrency 1
```

Each scenario uses the existing output limits and test timeouts. The `reasoning`
scenario records both HTTP and SSE responses. Review the captured request URLs,
response items, tool call IDs, reasoning data, and usage fields in
`test/support/fixtures/openai/gpt_6_astra/`. The expected URL ends in
`/v1/responses`. The recorder updates compatibility evidence from the results.

Replay the full set, then update and check the generated support reference:

```bash
mix mc "openai:gpt-6-astra" \
  --scenario basic,streaming,usage,token_limit,context_append,tool_multi,tool_none,tool_round_trip,object_basic,object_streaming,reasoning
mix req_llm.model_support --generate
mix req_llm.model_support --check
```

The focused `astra` capability routes to `test/coverage/openai/astra_test.exs`.
It checks async HTTP and SSE calls, delayed results across an intervening turn,
reasoning updates across three turns, automatic steering continuation, and
steering that requires a tool result on the same connection. See the
[Astra usage guide](openai.md#gpt-6-astra-experimental).

Record and replay these scenarios with the normal compatibility task:

```bash
mix mc "openai:gpt-6-astra" --capability astra --record --max-concurrency 1
mix mc "openai:gpt-6-astra" --capability astra --max-concurrency 1
```

HTTP and SSE use the standard fixture recorder. Persistent WebSocket sessions
use `ReqLLM.Test.WebSocketFixture`: a JSON transcript stores client calls and
raw server events in order. Replay uses a local WebSocket server and checks
every client frame against the saved transcript. It exercises the public
Responses session API across response boundaries. No connection headers or
credentials enter these transcripts. Recording uses the compatibility task's
staging directory; only passing scenarios replace fixtures.

CI replays both suites without API credentials:

```bash
REQ_LLM_FIXTURES_MODE=replay REQ_LLM_MODELS=openai:gpt-6-astra REQ_LLM_INCLUDE_RESPONSES=1 \
mix test test/coverage/openai/comprehensive_test.exs test/coverage/openai/astra_test.exs --include coverage
```

### Live results from 2026-09-04

The initial Astra fixture run recorded and replayed all 14 files for the 11
standard scenarios. HTTP, SSE, two-turn context, function tools, structured
objects, reasoning, usage, and the output limit all passed. The support evidence
classifies `openai:gpt-6-astra` on `openai.responses` as first-class for the
standard text baseline.

Five focused scenarios add nine live JSON files, for 23 files and 16 scenarios
in total. The focused checks cover:

- HTTP async calls with text, an intervening turn while the result is pending,
  and a delayed result with the original call ID.
- SSE async calls with text and retained async metadata.
- A reasoning update requesting `high`, with the request effort fixed at `low`
  across three turns. Manual history retains the earlier input prefix. The API
  accepts `prompt_cache_options.ttl` set to `30m`. These checks do not measure
  effective reasoning effort, cache hits, or cache cost savings.
- An accepted WebSocket steer, normal completion of the original response, and
  an automatic successor on the same connection.
- A pending steer that identifies a required tool result, then accepts that
  result with the original call ID on the same connection and completes.

The focused JSON files use the `astra_` prefix. They are part of the scenario
catalog, compatibility evidence, and CI replay. Failure events, disconnects,
interrupted responses, and validation of incompatible settings have local mock
tests. Live fixtures do not yet cover multiple simultaneous async jobs, stored
HTTP continuation with `previous_response_id`, async custom tools, or
multi-agent orchestration. The first-class classification applies to the
standard text baseline, not every optional Astra API feature.

One steering edge case was also observed. A steer can be accepted and later
fail with `response_not_active` if the original response reaches
`max_output_tokens` before the update is applied. Consumers must keep the steer
ID and process later failure events instead of treating acceptance as success.

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

The versioned `priv/model_compat_scenarios.json` artifact preserves finer-grained
evidence keyed by model, execution surface, and scenario. Each scenario keeps
its proof level and observation history, including timestamps, fixture names,
mode, status, errors, and the classified failure layer. The exact surface comes
from the recorded fixture request URL, so a replay cannot silently move to a
different provider API surface.

Run `mix req_llm.model_support --generate` to regenerate the deterministic
[`model support evidence reference`](model-support.md), and run
`mix req_llm.model_support --check` to verify both generated files. Support tiers
are descriptive compatibility-tool output only; ReqLLM continues to resolve
models independently of this evidence.

### Sparse Live Provider Drift Verification

Normal pull-request CI remains fixture replay only and requires no provider
credentials. The `Provider Drift` workflow adds a separate live lane that runs
manually or every Tuesday at 09:17 UTC. Its checked-in matrix lives in
`priv/provider_drift_anchors.json`:

| Provider | Model | Expected surface | Scenario |
| --- | --- | --- | --- |
| Anthropic | `claude-sonnet-4-5-20250929` | `anthropic.messages` | `basic` |
| Google | `gemini-2.0-flash` | `google.generate_content` | `basic` |
| OpenAI | `gpt-4o-mini` | `openai.responses` | `basic` |
| OpenAI | `chat-latest` | `openai.chat_completions` | `basic` |

The lane is bounded to four anchors, one concurrent request, 180 seconds and 64
output tokens per anchor, and an estimated maximum provider cost of $0.03 per
complete run. Missing credentials skip only their anchors. Failures report the
provider, model, expected or observed surface, scenario, classified failure
layer, remediation, and GitHub run correlation. Prompt and response bodies,
credential values, and staged fixtures are never included in its artifacts.

Validate the matrix without making provider requests:

```bash
mix req_llm.provider_drift --dry-run
```

Run the available anchors, or select one provider:

```bash
mix req_llm.provider_drift
mix req_llm.provider_drift --provider openai
```

Live probes capture fixtures only in a temporary directory long enough to
derive the actual execution surface, then delete them. They do not update
`priv/model_compat_scenarios.json`, support tiers, or checked-in fixtures. A
maintainer who deliberately wants new fixtures uses the separate existing
recording command:

```bash
mix req_llm.model_compat openai:gpt-4o-mini --scenario basic --record
```

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
- ✅ Usage metrics and best-effort cost calculation
- ✅ Tool calling (if advertised)
- ✅ Object generation (if advertised)
- ✅ Reasoning tokens (if advertised)

### What's NOT Guaranteed

- Complex edge cases beyond basic capabilities
- Provider-specific features not in model metadata
- Real-time behavior (fixtures may be cached)
- Exact API response formats (providers may change)
- Exact provider billing or invoice parity

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
