# ReqLLM Package Overview

## TL;DR

ReqLLM is a composable, provider-agnostic Elixir library built on Req and Finch that standardizes AI interactions around an OpenAI Chat Completions–like core. It normalizes prompts (Context/Message), models (Model), results (Response/StreamChunk), and tools (Tool), while providers plug in via a small behavior and Req pipeline steps for encoding/decoding and streaming.

## High-Level Architecture

ReqLLM follows a **narrow-waist design** with Chat Completions semantics at its center:

```
┌─────────────────────────────────────────────┐
│         ReqLLM Public API (Facade)          │
│  generate_text/stream_text/embed/etc.       │
└─────────────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
   ┌────▼─────┐           ┌──────▼──────┐
   │Generation│           │  Embedding  │
   │ Module   │           │   Module    │
   └────┬─────┘           └──────┬──────┘
        │                         │
        └────────────┬────────────┘
                     │
        ┌────────────▼────────────────┐
        │  Canonical Data Structures  │
        │  Model, Context, Message,   │
        │  Response, StreamChunk,     │
        │  Tool                       │
        └────────────┬────────────────┘
                     │
        ┌────────────▼────────────────┐
        │   Provider System           │
        │   (Behavior + Registry)     │
        └────────────┬────────────────┘
                     │
    ┌────────────────┼────────────────┐
    │                │                │
┌───▼────┐    ┌─────▼─────┐    ┌────▼─────┐
│OpenAI  │    │Anthropic  │    │  Google  │
│Provider│    │Provider   │    │  Provider│
└────────┘    └───────────┘    └──────────┘
```

**Key Principles:**
- **Pipeline-driven HTTP**: Non-streaming via Req pipeline steps; streaming via Finch with provider-supplied request builders
- **Metadata- and capability-aware**: Model metadata drives option validation, feature gating, and defaults
- **Testable by construction**: Fixture-first integration tests with deterministic replay

## Core Components

### 1. ReqLLM (lib/req_llm.ex)
**API Facade** - Single entry point for all operations
- Configuration: `put_key/2`, `get_key/1`
- Model parsing and provider lookup
- Context ergonomics: `context/1`
- Delegates to specialized modules: Generation, Embedding
- Utilities: `tool/2`, `json_schema/1`, `cosine_similarity/2`
- Accepts model specs in multiple formats: `"openai:gpt-4o"`, `{:openai, "gpt-4o"}`, `%Model{}`

### 2. Model (lib/req_llm/model.ex)
**Canonical model value object**
- Fields: provider, model name, retry/limits/capabilities/cost
- Resolution: `from/1` parses strings/tuples/structs
- Metadata: `with_metadata/1` hydrates full provider metadata
- Defaults: `with_defaults/1` fills sensible defaults
- Integrates with Provider.Registry and Metadata system

### 3. Context & Message (lib/req_llm/context.ex, lib/req_llm/message.ex)
**Normalized conversation representation**
- **Context**: Ordered messages + tools; normalizes arbitrary input (string, maps, Message, Context, list)
- **Message**: Strictly typed, multi-modal via `ContentPart` list; supports tool calls on assistant messages
- Builders: `user/1`, `assistant/1`, `system/1`, `tool/2`
- Validation: roles, tool_call_id, system message rules

### 4. Response (lib/req_llm/response.ex)
**Canonical result of an LLM turn**
- Contains: new assistant/tool Message, merged Context, usage/finish_reason/provider_meta
- Helpers: `text/1`, `thinking/1`, `tool_calls/1`, `usage/1`, `reasoning_tokens/1`
- Streaming: `text_stream/1`, `object_stream/1`, `join_stream/1`
- Provider-agnostic decoding: `decode_response/2`, `decode_object/3` (for fixture testing)

### 5. StreamChunk (lib/req_llm/stream_chunk.ex)
**Uniform streaming event type** across all providers
- Types: `:content`, `:thinking`, `:tool_call`, `:meta`
- Constructors + validation
- Enables provider-agnostic streaming consumers

### 6. Tool (lib/req_llm/tool.ex)
**Function calling definition**
- Fields: name, description, schema, callback, strict mode
- Schema adapters: OpenAI/Anthropic/Google/Bedrock Converse
- NimbleOptions validation
- Execution support

### Supporting Modules
- **Generation, Embedding**: Operation orchestrators (chat/object/stream, embeddings)
- **Capability**: Computes supported capability flags per model
- **Schema**: Compiles NimbleOptions/JSON Schema and converts to provider formats
- **Step.Usage**: Response step that extracts usage via provider callback
- **Streaming.SSE**: Default SSE accumulator/parser

## Provider System Architecture

### Provider Behavior (lib/req_llm/provider.ex)

Providers implement a small behavior with these callbacks:

**Required:**
- `prepare_request/4`: Build Req.Request per operation (`:chat`, `:object`, `:embed`, etc.)
- `attach/3`: Attach auth and pipeline steps (encode_body, decode_response)
- `encode_body/1`: Convert canonical Context/options → provider JSON (request step)
- `decode_response/1`: Convert provider HTTP response → `%ReqLLM.Response{}` (response step)

**Optional:**
- `extract_usage/2`: Usage/cost extraction for Step.Usage
- `normalize_model_id/1`: Map aliases to canonical IDs
- `translate_options/3`: Map canonical options to provider-specific parameters
- **Streaming:**
  - `attach_stream/4`: Build Finch.Request end-to-end
  - `parse_stream_protocol/2`: Defaults to SSE
  - `decode_stream_event/2`: Stateless mapping to StreamChunk
  - Or stateful: `init_stream_state/1` + `decode_stream_event/3` + `flush_stream_state/2`
- `thinking_constraints/0`: Enforce platform constraints for reasoning models

### Provider DSL & Registry
- **Provider.DSL**: Macro to declare id, base_url, metadata files
- **Provider.Registry**: Maps provider atom → module; metadata lookup, capabilities
- **Provider.Options**: Validates, normalizes, and precomputes options per operation

### Req Pipeline Integration
Providers compose Req request/response steps for reusable, testable encoding/decoding. `Step.Usage` automatically invoked after decode to unify usage metadata.

## Data Flow

### Non-Streaming (Chat/Object)
```
1. ReqLLM.generate_text/generate_object
   ↓
2. Model.from(string/tuple/struct) → Provider.Registry.fetch(provider)
   ↓
3. Context.normalize(prompt/messages) + optional schema compilation
   ↓
4. Provider.Options.process! (merge, validate, translate)
   ↓
5. Provider.prepare_request(:chat|:object, model, context, opts)
   ↓
6. Provider.attach(request, model, opts) → registers encode_body + decode_response
   ↓
7. Req.run(request) → HTTP → decode_response/1 builds %Response{}
   ↓
8. Step.Usage.handle extracts token/cost usage
   ↓
9. Response with merged context, text, tool_calls, usage
```

### Streaming (Chat/Object)
```
1. ReqLLM.stream_text/stream_object (stream: true)
   ↓
2. Provider.attach_stream builds Finch.Request (headers/body)
   ↓
3. Streaming loop pulls chunks → parse_stream_protocol/2 (SSE default)
   ↓
4. decode_stream_event/2 converts events → StreamChunk(s)
   ↓
5. Response contains stream (Enumerable of StreamChunk)
   ↓
6. Consumers use text_stream/object_stream or join_stream/1
```

### Embeddings
- `ReqLLM.embed` → Embedding module → Provider.prepare_request(`:embed`) → attach/encode/decode (same pattern as chat)

### Structured Output (Object Generation)
- Canonical pattern: tool call named `"structured_output"` with arguments validated against caller's schema
- `decode_object/3` wraps `decode_response/2` + schema validation
- Streaming: `object_stream/1` materializes final object

## Testing Strategy

### Three-Tier Test Pyramid

**Tier 1: Core Tests** (`test/req_llm/`)
- Pure unit tests; no I/O
- Model parsing, schema compilation, errors, registry

**Tier 2: Provider Tests** (`test/providers/`)
- Mocked provider logic
- Parameter translation, encode/decode codecs
- No API calls

**Tier 3: Coverage Tests** (`test/coverage/`)
- Fixture-based integration across providers and models
- Tests only public API (`generate`/`stream`/`embed`)

### Fixture System

**Default**: Replay recorded fixtures (fast, deterministic)

**Live Re-record**: `REQ_LLM_FIXTURES_MODE=record mix test`

**Environment Variables:**
- `REQ_LLM_MODELS`: Select all, by provider, or comma-separated list
- `REQ_LLM_SAMPLE`: Sample N models per provider
- `REQ_LLM_EXCLUDE`: Exclusion list
- `REQ_LLM_INCLUDE_RESPONSES`: Opt-in to OpenAI /v1/responses models

**Shared Provider Macros:**
- `use ReqLLM.ProviderTest.Core` / `Streaming` generates consistent scenario matrix
- Scenarios: basic, streaming, token_limit, usage, tools, object, reasoning
- Transparent fixture capture and replay

**Test Utilities:**
- `Req.Test.stub` for custom HTTP mocks
- `Response.decode_response/2` validates decoders against raw JSON

## Key Design Patterns

### Facade Pattern
ReqLLM exposes small, uniform public surface; delegates to specialized modules

### Strategy/Adapter Pattern
Provider behavior encapsulates provider-specific logic behind canonical interface

### Pipeline Pattern (Req Steps)
Providers plug `encode_body/1` and `decode_response/1` into Req's request/response pipelines

### Iterator/Stream Pattern
Streaming as Enumerable of StreamChunk; consumers map/filter/collect; `join_stream` materializes Response

### Value Objects & Immutability
Model, Context, Message, Response, StreamChunk, Tool are typed structs; no polymorphism

### Narrow Waist + Translation Layers
Canonical Chat Completions semantics; providers translate to their APIs

### Capability-Driven Behavior
Model metadata augments defaults, limits, modalities, costs; drives feature gating

### Validation-First
NimbleOptions for tools/parameters; schema compilation; strict validation; unified usage parsing

## What Makes It Composable & Extensible

1. **Composable Data Flow**: Context normalization + Req pipeline steps + Response helpers = small, swappable pieces
2. **Provider Plug Points**: Handful of callbacks cover streaming, options, usage; defaults provided (e.g., SSE)
3. **Uniform Streaming Model**: StreamChunk types unify provider quirks; shared client logic
4. **Schema-First Tools/Objects**: Single schema pipeline with provider adapters
5. **Minimal Infrastructure**: Reuses Req/Finch; clean boundaries; small interfaces

## Codebase Navigation

### Core Modules
- `ReqLLM`, `Model`, `Capability`, `Keys`, `Metadata`, `ParamTransform`, `Error`

### Data Structures
- `Message` (+ `ContentPart`), `Context`, `Response` (+ `StreamResponse`), `StreamChunk`, `Tool` (+ `ToolCall`), `Schema`

### Provider API
- `Provider`, `Provider.DSL`, `Provider.Registry`, `Provider.Options`, `Provider.Utils`, `Provider.Defaults`

### Operations
- `Generation` (chat/object/stream), `Embedding`

### Streaming
- `Streaming.SSE` and provider streaming callbacks

### Tests
- `test/req_llm/` - Core unit tests
- `test/providers/` - Provider mocked tests
- `test/coverage/` - Fixture-based integration
- `ProviderTest` macros in `test/support/`

## Model Registry & Metadata System

ReqLLM uses a sophisticated **three-layer metadata system** to manage provider and model information:

### 1. Base Catalog Layer (`ReqLLM.Catalog.Base`)
**Compile-time metadata source** - Zero runtime I/O
- Built from `priv/models_dev/*.json` (synced from models.dev via `mix req_llm.model_sync`)
- Loaded at compile time via macro in `ReqLLM.Catalog.Base.base()`
- Contains provider metadata and all available models with:
  - Capabilities (reasoning, tool_call, temperature, attachment)
  - Limits (context window, output tokens, rate limits)
  - Costs (input/output pricing per million tokens)
  - Modalities (text, image, audio, video support)
  - Knowledge cutoff dates and release dates

### 2. Catalog Layer (`ReqLLM.Catalog`)
**Runtime configuration layer** - Applies filters and overrides
- Loads base catalog and applies:
  - **Allowlist filtering** (`config :req_llm, :catalog, allow:`) - Controls which models are available
  - **Custom providers/models** (`custom:`) - Add local models (VLLM, LLaMA CPP)
  - **Metadata overrides** (`overrides:`) - Deep merge patches for provider/model metadata
- Processing order:
  1. Load base catalog
  2. Merge custom entries
  3. Filter by allowlist (supports wildcards: `["gpt-*", "claude-3.5-*"]`)
  4. Apply provider-level overrides
  5. Apply model-level overrides
- Produces "effective catalog" for the registry

### 3. Provider Registry (`ReqLLM.Provider.Registry`)
**Runtime registry** - Fast read-only access via `:persistent_term`
- Initialized from effective catalog at startup
- Maps `provider_id => %{module: ProviderModule, metadata: %{...}}`
- Supports:
  - **Implemented providers**: Full module + metadata (can make API calls)
  - **Metadata-only providers**: Just metadata, no module (cannot make API calls)
- Functions:
  - `get_provider/1` - Get provider module
  - `get_model/2` - Get model with hydrated metadata
  - `list_providers/0` - All registered providers
  - `list_models/1` - Models for a provider
  - `model_exists?/1` - Check if model spec exists
  - `get_env_key/1` - Get API key environment variable name

### Metadata Schema (`ReqLLM.Metadata`)
**Unified validation and normalization**
- NimbleOptions schemas for:
  - **Connection** - Provider API configuration (base_url, auth, timeouts)
  - **Capabilities** - Model feature flags (reasoning, tools, temperature, modalities)
  - **Limits** - Token limits (context, output, rate limits)
  - **Costs** - Pricing (input/output/cache/training costs per million tokens)
- Functions:
  - `validate/2` - Validate metadata against schema
  - `build_capabilities_from_metadata/1` - Extract capability flags
  - `map_string_keys_to_atoms/1` - Safe string-to-atom conversion

### Capability System (`ReqLLM.Capability`)
**Programmatic capability discovery**
- Query what features are supported by specific models
- Functions:
  - `capabilities/1` - Get all capabilities for a model
  - `supports?/2` - Check if model supports a capability
  - `supports_object_generation?/1` - Check structured output support
  - `models_for/2` - Get models supporting a capability
  - `providers_for/1` - Get providers with capability support
  - `validate!/2` - Validate model supports required options

### Configuration Examples

**Allowlist in config/catalog_allow.exs:**
```elixir
config :req_llm, :catalog,
  allow: %{
    anthropic: :all,  # All Anthropic models
    openai: ["gpt-4o", "gpt-4o-mini", "gpt-4*"],  # Specific + wildcard
    google: :all
  }
```

**Custom provider:**
```elixir
config :req_llm, :catalog,
  custom: [
    %{
      provider: %{id: "local_vllm", base_url: "http://localhost:8000/v1"},
      models: [%{id: "llama-3-70b", context: 8192}]
    }
  ]
```

**Metadata override:**
```elixir
config :req_llm, :catalog,
  overrides: [
    models: %{
      openai: %{
        "gpt-4o" => %{"cost" => %{"input" => 2.5, "output" => 10.0}}
      }
    }
  ]
```

### Model Selection for Tests (`ReqLLM.Test.ModelMatrix`)
**Declarative test model selection**
- Respects catalog allowlist patterns
- Environment variables:
  - `REQ_LLM_MODELS` - Pattern (`:all`, `"provider:*"`, `"provider:model,..."`)
  - `REQ_LLM_OPERATION` - Filter by operation (`:text`, `:embedding`)
  - `REQ_LLM_SAMPLE` - Sample N models per provider
  - `REQ_LLM_EXCLUDE` - Exclude specific models
- Functions:
  - `selected_specs/1` - Get models based on config
  - `models_for_provider/2` - Filter by provider

### Data Flow: Model Metadata Loading
```
1. Compile time: models.dev → priv/models_dev/*.json
   ↓
2. Compile time: ReqLLM.Catalog.Base.base() macro loads JSON
   ↓
3. Application start: ReqLLM.Catalog.load() applies config
   ↓ (allowlist + custom + overrides)
4. Registry.initialize(catalog) → :persistent_term storage
   ↓
5. Model.from("provider:model") → Registry.get_model()
   ↓ (hydrates capabilities, limits, costs)
6. Enhanced Model struct with full metadata
```

## Directory Structure
```
lib/req_llm/
├── provider.ex              # Provider behavior definition
├── provider/                # Provider system internals
│   ├── registry.ex         # :persistent_term provider/model registry
│   ├── dsl.ex              # Provider DSL macro
│   ├── options.ex          # Option validation and translation
│   ├── defaults.ex         # Default values
│   └── metadata.ex         # Metadata loading helpers
├── providers/               # Provider implementations
│   ├── openai.ex
│   ├── anthropic.ex
│   ├── google.ex
│   └── ...
├── model.ex                 # Model struct & resolution
├── model/
│   └── metadata.ex         # Model metadata loading from priv/
├── context.ex               # Context normalization
├── message.ex               # Message + ContentPart
├── response.ex              # Response struct & helpers
├── stream_chunk.ex          # StreamChunk types
├── tool.ex                  # Tool definitions
├── capability.ex            # Capability discovery and validation
├── catalog.ex               # Runtime catalog with filters/overrides
├── catalog/
│   └── base.ex             # Compile-time base catalog
├── metadata.ex              # Unified metadata schemas (NimbleOptions)
├── generation.ex            # Chat/object operations
├── embedding.ex             # Embedding operations
├── streaming/               # Streaming infrastructure
│   └── sse.ex
└── step/                    # Req pipeline steps
    └── usage.ex

priv/
├── models_dev/              # Synced from models.dev (mix req_llm.model_sync)
│   ├── .catalog_manifest.json
│   ├── anthropic.json
│   ├── openai.json
│   ├── google.json
│   └── ...
└── supported_models.json    # Auto-generated fixture state

config/
├── config.exs               # Main config (catalog_enabled?)
├── catalog_allow.exs        # Allowlist configuration
└── test.exs                 # Test-specific config

test/support/
└── model_matrix.ex          # Test model selection helper
```
