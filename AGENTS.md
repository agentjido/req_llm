# AGENTS.md - ReqLLM Development Guide

## Project Overview
ReqLLM is a composable Elixir library for AI interactions built on Req, providing a unified interface to AI providers through a plugin-based architecture.

## Common Commands

### Build & Test
- `mix test` - Run all tests using cached fixtures
- `mix test test/req_llm_test.exs` - Run specific test file
- `mix test --only describe:"model/1 top-level API"` - Run specific describe block
- `mix test --only openai` - Run tests for specific provider using ExUnit tags
- `mix test --only coverage` - Run capability coverage tests
- `LIVE=true mix test` - Run against real APIs and (re)generate fixtures
- `LIVE=true mix test --only openai` - Regenerate fixtures for single provider
- `mix compile` - Compile the project
- `mix quality` or `mix q` - Run quality checks (format, compile --warnings-as-errors, dialyzer, credo)

### Code Quality
- `mix format` - Format Elixir code
- `mix format --check-formatted` - Check if code is properly formatted
- `mix dialyzer` - Run Dialyzer type analysis
- `mix credo --strict` - Run Credo linting

## Architecture & Structure

### Core Structure
- `lib/req_llm.ex` - Main API facade with generate_text/3, stream_text/3, generate_object/4
- `lib/req_llm/` - Core modules (Model, Provider, Error structures, protocols)
- `lib/req_llm/providers/` - Provider-specific implementations (Anthropic, OpenAI, etc.)
- `test/` - Consolidated capability-oriented test suites
  - `coverage/<provider>/` - Provider-specific capability tests  
  - `support/` - shared helpers (e.g. `live_fixture.ex`, provider test macros)
  - Test files are intentionally few and broad; new behavior should extend an existing suite when possible instead of adding many micro-tests

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
  - `prepare_request/4` - Configure operation-specific requests
  - `attach/3` - Set up authentication and Req pipeline steps
  - `encode_body/1` - Transform context to provider JSON
  - `decode_response/1` - Parse API responses
  - `extract_usage/2` - Extract usage/cost data (optional)
  - `translate_options/3` - Provider-specific parameter translation (optional)
- Providers use `ReqLLM.Provider.DSL` macro for registration and metadata loading
- Core API uses provider's `attach/3` to compose Req requests with provider-specific steps
- **Options Translation**: Providers can implement `translate_options/3` to handle model-specific parameter requirements (e.g., OpenAI o1 models require `max_completion_tokens` instead of `max_tokens`)

### Protocol System
- `ReqLLM.Context.Codec` - Protocol for encoding/decoding contexts to/from provider wire formats
- `ReqLLM.Response.Codec` - Protocol for decoding provider responses to canonical Response structs
- Each provider implements these protocols for their specific data formats

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
