# AGENTS.md - ReqLLM Development Guide

**IMPORTANT: DO NOT WRITE COMMENTS INTO THE BODY OF ANY FUNCTIONS.**

## Project Overview
ReqLLM is a composable Elixir library for AI interactions built on Req, providing a unified interface to AI providers through a plugin-based architecture. The library uses OpenAI Chat Completions as the baseline API standard, with providers implementing translation layers for non-compatible APIs.

## Common Commands

### Build & Test
- `mix test` - Run all tests using cached fixtures
- `mix test test/req_llm_test.exs` - Run specific test file
- `mix test --only describe:"model/1 top-level API"` - Run specific describe block
- `LIVE=true mix test` - Run against real APIs and (re)generate fixtures
- `REQ_LLM_DEBUG=1 mix test` - Run tests with verbose fixture debugging output
- `mix compile` - Compile the project
- `mix quality` or `mix q` - Run quality checks (format, compile --warnings-as-errors, dialyzer, credo)

### Coverage Validation
- `mix mc` or `mix req_llm.model_compat` - Show models with passing fixtures
- `mix mc "*:*"` - Validate all models (parallel, fixture-based)
- `mix mc --sample` - Validate sample model subset (config/config.exs)
- `mix mc anthropic` - Validate all Anthropic models
- `mix mc "openai:gpt-4o"` - Validate specific model
- `mix mc "xai:*" --record` - Re-record fixtures for xAI models
- `mix mc --available` - List all models from registry (priv/models_dev/)

**Coverage System Architecture:**
- **Model Registry**: `priv/models_dev/*.json` (synced via `mix req_llm.model_sync`)
- **Fixture State**: `priv/supported_models.json` (auto-generated artifact)
- **Parallel Execution**: Tests run concurrently for speed
- **State Tracking**: Skips models with passing fixtures unless `--record` or `--record-all`

#### Test Filtering with Semantic Tags
ReqLLM uses structured key/value tags for precise test filtering:

**Tag Dimensions:**
- `category` - Test type (`:core`, `:streaming`, `:tools`, `:embedding`)
- `provider` - LLM provider (`:anthropic`, `:openai`, `:google`, `:groq`, `:openrouter`, `:xai`)

**Examples:**
- `mix test --only "category:core"` - Run all core tests
- `mix test --only "provider:anthropic"` - Run Anthropic tests only
- `mix test --only "category:core" --only "provider:openrouter"` - Run OpenRouter core tests
- `LIVE=true mix test --only "category:core" --only "provider:anthropic"` - Regenerate Anthropic core fixtures

### Code Quality
- `mix format` - Format Elixir code
- `mix format --check-formatted` - Check if code is properly formatted
- `mix dialyzer` - Run Dialyzer type analysis
- `mix credo --strict` - Run Credo linting (includes custom rule to enforce no comments in function bodies)

## Architecture & Structure

### Core Structure
- `lib/req_llm.ex` - Main API facade with generate_text/3, stream_text/3, generate_object/4
- `lib/req_llm/` - Core modules (Model, Provider, Error structures)
- `lib/req_llm/providers/` - Provider-specific implementations (Anthropic, OpenAI, etc.)
- `test/` - Three-tier testing architecture (see `test/AGENTS.md` for detailed testing guide)
  - `test/req_llm/` - Core package tests (NO API calls, unit tests with mocks)
  - `test/provider/` - Mocked provider-specific tests (NO API calls, tests provider nuances)
  - `test/coverage/` - Live API coverage tests (fixture-based, high-level API only)
  - `test/support/` - Shared helpers (live fixtures, HTTP mocks, test macros)

### Core Data Structures
- `ReqLLM.Context` - Conversation history as a collection of messages
- `ReqLLM.Message` - Single conversation message with multi-modal content support
- `ReqLLM.Message.ContentPart` - Individual content piece (text, image, tool call, etc.)
- `ReqLLM.Tool` - Function calling definition with schema and callback
- `ReqLLM.StreamChunk` - Unified streaming response format across providers
- `ReqLLM.Model` - AI model configuration with provider and parameters
- `ReqLLM.Response` - High-level LLM response with context and metadata

### Provider Architecture
- Each provider implements `ReqLLM.Provider` behavior with callbacks:
  - `prepare_request/4` - Configure operation-specific requests (non-streaming only)
  - `attach/3` - Set up authentication and Req pipeline steps (non-streaming only)
  - `encode_body/1` - Transform context to provider JSON (non-streaming only)
  - `decode_response/1` - Parse API responses (non-streaming only)
  - `attach_stream/4` - Build complete Finch streaming request (streaming only, optional)
  - `decode_sse_event/2` - Decode provider SSE events to StreamChunk structs (streaming only, optional)
  - `extract_usage/2` - Extract usage/cost data (optional)
  - `translate_options/3` - Provider-specific parameter translation (optional)
- Providers use `ReqLLM.Provider.DSL` macro for registration and metadata loading
- **Non-streaming**: Core API uses provider's `attach/3` to compose Req requests with provider-specific steps
- **Streaming**: Uses Finch with provider's `attach_stream/4` to build streaming requests and `decode_sse_event/2` to parse SSE events
- **Options Translation**: Providers can implement `translate_options/3` to handle model-specific parameter requirements (e.g., OpenAI o1 models require `max_completion_tokens` instead of `max_tokens`)

### Encoding/Decoding System
- Provider callbacks handle encoding/decoding requests and responses
- Built-in defaults provide OpenAI-style wire format handling
- Providers can override `encode_body/1` and `decode_response/1` for custom formats

## Code Style & Conventions

### General Style
- Follow standard Elixir conventions and use `mix format` for consistent formatting
- Use `@moduledoc` and `@doc` for comprehensive documentation
- Prefer pattern matching over conditionals where possible
- Use `{:ok, result}` / `{:error, reason}` tuple returns for fallible operations
- **No inline comments in method bodies** - code should be self-explanatory through clear naming and structure

### Imports & Dependencies
- Minimize imports, prefer explicit module calls (e.g., `ReqLLM.Model.from/1`)
- Group deps in mix.exs: runtime deps first, then dev/test deps with `, only: [:dev, :test]`

### Types & Validation
- Use TypedStruct for structured data with `@type` definitions
- Validate options with NimbleOptions schemas in public APIs
- Use Splode for structured error handling with specific error types

### Error Handling
- Return `{:ok, result}` or `{:error, %ReqLLM.Error{}}` tuples
- Use Splode error types: `ReqLLM.Error.API`, `ReqLLM.Error.Parse`, `ReqLLM.Error.Auth`
- Include helpful error messages and context in error structs

### Testing & Fixture Workflow
- Tests are grouped by *capability*, not by individual function-call
- All suites use `ReqLLM.Test.LiveFixture.use_fixture/3` to abstract live vs cached responses
- Cached JSON fixtures live next to the test in `fixtures/<provider>/<test_name>.json` and are automatically written when the `LIVE=true` env-var is set
- Most suites run `async: true`. Suites that write fixtures are forced to synchronous execution via `@moduletag :capture_log`

```elixir
defmodule CoreTest do
  use ReqLLM.Test.LiveFixture, provider: :openai
  use ExUnit.Case, async: true

  describe "generate_text/3" do
    test "basic happy-path" do
      {:ok, text} =
        use_fixture(:provider, "core-basic", fn ->
          ReqLLM.generate_text!("openai:gpt-4o", "Hello!")
        end)

      assert text =~ "Hello"
    end
  end
end
```
