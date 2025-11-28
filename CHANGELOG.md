# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **ReqLLM.ModelHelpers capability helper functions** for type-safe model capability access
  - Centralized helpers like `ReqLLM.ModelHelpers.json_schema?/1`, `ReqLLM.ModelHelpers.tools_strict?/1`
  - Replaces scattered `get_in(model.capabilities, ...)` calls across providers
  - Fixes bug in Bedrock provider where reasoning capability was checked incorrectly (was checking `capabilities.reasoning` map instead of `capabilities.reasoning.enabled` boolean)
  - Provides single source of truth for capability access patterns
  - Compile-time generated functions from capability schema paths
- **Amazon Bedrock service tier support** for request prioritization
  - `service_tier` option with values: `"priority"`, `"default"`, `"flex"`
  - Priority tier provides faster responses at premium cost for mission-critical workloads
  - Flex tier offers cost-effective processing for non-urgent tasks
  - Supported on compatible Bedrock models (check AWS documentation for availability)
- **Google Vertex AI Gemini model support**
  - Gemini 2.0 Flash, 2.5 Flash, 2.5 Flash Lite, and 2.5 Pro on Google Vertex AI
  - Delegates to native Google provider format with Vertex-specific quirks handled
  - Sanitizes function call IDs (Vertex API rejects them while direct Google API includes them)
  - Full support for extended thinking/reasoning, context caching, and all Gemini features
  - Complete fixture coverage for all Vertex Gemini models (46 fixtures: 10 for 2.0, 12 each for 2.5 variants)
- **Google Context Caching** for Gemini models with up to 90% cost savings
  - `ReqLLM.Providers.Google.CachedContent` module for cache CRUD operations
  - Create, list, update, and delete cached content
  - Support for both Google AI Studio and Vertex AI (requires Gemini models)
  - `cached_content` provider option to reference existing caches
  - Minimum token requirements: 1,024 (Flash) / 4,096 (Pro)
- **OAuth2 token caching for Google Vertex AI**
  - Eliminates 60-180ms auth overhead on every request
  - Tokens cached for 55 minutes (5 minute safety margin before 1 hour expiry)
  - GenServer serializes concurrent refresh requests to prevent duplicate fetches
  - Per-node cache (no distributed coordination needed)
  - 99.9% reduction in auth overhead for typical workloads
- **Real-time stream processing** with `ReqLLM.StreamResponse.process_stream/2`
  - Process streams incrementally with real-time callbacks
  - `on_result` callback for content chunks (fires immediately as text arrives)
  - `on_thinking` callback for reasoning/thinking chunks (fires immediately)
  - Prevents double-stream consumption bugs through single-pass processing
  - Enables real-time streaming to UIs (Phoenix LiveView, websockets, etc.)
  - No upfront `Enum.to_list` - callbacks fire as chunks arrive from the stream
- **Provider alias support** via llm_db integration
  - Google Vertex AI Anthropic models now accessible via `:google_vertex` provider
  - `google_vertex_anthropic` provider aliased to `google_vertex` implementation
  - Enables single provider module to serve models from multiple llm_db providers
  - Complete fixture coverage for all Vertex Claude models (36 fixtures: 12 per model × 3 models)
- **provider_model_id support** for AWS Bedrock inference profiles
  - Models can specify API-specific identifiers separate from canonical IDs
  - Enables Bedrock streaming and on-demand throughput with inference profile prefixes
  - Applied to Claude Haiku 4.5, Sonnet 4.5, Opus 4.1, Llama 3.3 70B models
- **Credential fallback for fixture recording** in providers requiring cloud credentials
  - Automatic fallback to existing fixtures when credentials are missing during RECORD mode
  - Provider-specific credential detection via optional `credential_missing?/1` callback
  - Implemented in AWS Bedrock, Google, and Google Vertex AI providers
  - Enables comprehensive test coverage without requiring all developers to configure cloud credentials

### Enhanced

- **AWS Event Stream parser documentation** clarifying Bedrock specialization
  - Explains performance rationale for single-pass parsing and header specialization
  - Documents non-goals (S3 Select, Transcribe, Kinesis incompatibility)
- **Object generation detection** updated to recognize tool-based workaround
  - `supports_object_generation?` now accepts models with `tools.enabled = true`
  - Enables object generation tests for Vertex Claude models using tool workaround

### Fixed

- **Test helper `tool_budget_for/1` pattern match regression** from LLMDB integration
  - Fixed pattern match to use `{:ok, model}` instead of obsolete `{:ok, {provider, id, model}}`
  - Fixed field name from `model.limit` to `model.limits`
  - Regression introduced in v1.1.0 caused test fixtures to use incorrect `maxOutputTokens` values
  - Primarily affected reasoning-enabled models (Gemini 2.5 Pro) where 150 token default was insufficient
- **Google provider cached token extraction** from API responses
  - Extracts `cachedContentTokenCount` from `usageMetadata` for both implicit and explicit caching
  - Converts to OpenAI-compatible `prompt_tokens_details.cached_tokens` format
  - Fixes cached tokens always showing as 0 even when caching was active
  - Affects both `google` and `google-vertex` providers using Gemini models
- **JSV schema validation** now preserves original data types instead of returning cast values
  - Prevents unwanted type coercion (e.g., 1.0 → 1 for integer schemas)
  - Validation still enforces schema constraints, but returns original input data
- **JSV schema compilation** performance improved with ETS-based caching
  - Compiled schemas cached globally to avoid redundant JSV.build!/1 calls
  - Configured with read_concurrency for fast concurrent access
- Google Vertex AI provider guide missing from documentation
  - Added google_vertex.md to mix.exs extras and Providers group

## [1.0.0] - 2025-11-02

### Added

- **Google Vertex AI provider** with comprehensive Claude 4.x support
  - OAuth2 authentication with service accounts
  - Full Claude model support (Haiku 4.5, Sonnet 4.5, Opus 4.1)
  - Extended thinking and prompt caching capabilities
  - Complete fixtures for all Vertex AI Claude models
- **AWS Bedrock inference profile models** with complete fixture coverage
  - Anthropic Claude inference profiles (Haiku 4.5, Sonnet 4.5, Opus 4.1)
  - OpenAI OSS models (gpt-oss-20b, gpt-oss-120b)
  - Meta Llama inference profiles
  - Cohere Command R and Command R Plus models
- **Provider base URL override** capability via application config
  - Enables testing with mock services
  - Configured per-provider in application config
- AWS Bedrock API key authentication support (introduced by AWS in July 2025)
  - Simple Bearer token authentication as alternative to IAM credentials
  - `api_key` provider option with `AWS_BEARER_TOKEN_BEDROCK` environment variable fallback
  - Short-term keys (up to 12 hours) recommended for production
  - Long-term keys available for exploration
  - Limitations: Cannot use with InvokeModelWithBidirectionalStream, Agents, or Data Automation
- **Context tools persistence** for AWS Bedrock multi-turn conversations
  - Tools automatically persist in context after first request
  - Bedrock-specific implementation with zero impact on other providers
- **Schema map-subtyped list support** for complex nested structures
  - Properly handles `{:list, {:map, schema}}` type definitions
  - Generates correct JSON Schema for nested object arrays

### Enhanced

- **Google provider v1beta API** as default version
  - Fixes streaming compatibility issues
  - Updated all test fixtures to use v1beta
- **Test configuration** expanded with additional LLM providers
  - Enhanced catalog_allow settings for broader provider coverage
- **Documentation organization** with refactored guides structure
  - Improved provider-specific documentation
  - Better task organization in mix.exs

### Fixed

- **Streaming protocol callback renamed** from `decode_sse_event` to `decode_stream_event`
  - More protocol-agnostic naming (supports SSE, AWS Event Stream, etc.)
  - Affects all providers implementing streaming
- **Groq UTF-8 boundary handling** in streaming responses
  - Prevents crashes when UTF-8 characters split across chunk boundaries
- **Schema boolean encoding** preventing invalid string coercion
  - Boolean values now correctly encoded in normalized schemas
- **OpenAI model list typo** corrected in documentation
- AWS Bedrock Anthropic inference profile model ID preservation
  - Added `preserve_inference_profile?/1` callback to Anthropic Bedrock formatter
  - Ensures region prefixes (global., us.) are preserved in API requests
  - Fixes 400 "invalid model identifier" errors for inference profile models
- AWS Bedrock Converse API usage field parsing
  - Fixed `parse_usage/1` to include all required fields (reasoning_tokens, total_tokens, cached_tokens)
  - Fixes KeyError when accessing usage fields from Converse API responses
- AWS Bedrock model ID normalization for metadata lookup
  - Fixed `normalize_model_id/1` to always strip region prefixes for Registry lookups
  - Enables capabilities detection for inference profile models
  - Separates metadata lookup (always normalized) from API requests (preserve_inference_profile? controls)
- AWS Bedrock provider model family support
  - Added Meta to @model_families for Llama models using Converse API
  - Added OpenAI to @model_families for gpt-oss models
  - Cohere Command R models use Converse API directly with full tool support (no custom formatter needed)

### Notes

This is the first stable 1.0 release of ReqLLM, marking production readiness with comprehensive provider support, robust streaming, and extensive test coverage. The library now supports 15+ providers with 750+ models and includes advanced features like prompt caching, structured output, tool calling, and embeddings.

## [1.0.0-rc.8] - 2025-10-29

### Added

- **Prompt caching support for Bedrock Anthropic models** (Claude on AWS Bedrock)
  - Auto-switches to native API when caching enabled with tools for full cache control
  - Supports caching of system prompts and tools
  - Provides warning when auto-switching (silenceable with explicit `use_converse` setting)
- **Structured output (`:object` operation) support for AWS Bedrock provider**
  - Bedrock Anthropic sub-provider using tool-calling approach
  - Bedrock Converse API for unified structured output across all models
  - Bedrock OpenAI sub-provider (gpt-oss models)
- **Google Search grounding support** for Google Gemini models via built-in tools
  - New `google_grounding` option to enable web search during generation
  - API versioning support (v1 and v1beta) for Google provider
  - Grounding metadata included in responses when available
- **JSON Schema validation** using JSV library (supports draft 2020-12 and draft 7)
  - Client-side schema validation before sending to providers
  - Better error messages for invalid schemas (e.g., embedded JSON strings vs maps)
  - Validates raw JSON schemas via `ReqLLM.Schema.validate/2`
- **Model catalog feature** for runtime model discovery
- **Configurable `metadata_timeout` option** for long-running streams (default: 60s)
  - Application-level configuration support
  - Fixes metadata collection timeout errors on large documents
- **HTTP streaming in StreamServer** with improved lifecycle management
- Direct JSON schema pass-through support for complex object generation
- Base URL override capability for testing with mock services
- API key option in provider defaults with proper precedence handling
- `task_type` parameter support for Google embeddings

### Enhanced

- **Bedrock provider with comprehensive fixes and improvements**
  - Streaming temperature/top_p conflict resolution via Options.process pipeline
  - Extended thinking (reasoning) support with proper `reasoning_effort` translation
  - Tool round-trip conversations by extracting stub tools from messages
  - Complete usage metadata fields (cached_tokens, reasoning_tokens) for all models
  - Increased receive timeout from 30s to 60s for large responses
  - Unified streaming and non-streaming to use Options.process pipeline
  - Uses model capabilities instead of hardcoded model IDs for reasoning support detection
- **Meta/Llama support refactored into reusable generic provider**
  - Created `ReqLLM.Providers.Meta` for Meta's native prompt format
  - Bedrock Meta now delegates to generic provider for format conversion
  - Enables future Azure AI Foundry and Vertex AI support
  - Documents that most providers (Azure, Vertex AI, vLLM, Ollama) use OpenAI-compatible APIs
- **OpenAI provider** with JSON Schema response format support for GPT-5 models
- **Streaming error handling** with HTTP status code validation
  - Proper error propagation for 4xx/5xx responses
  - Prevents error JSON from being passed to SSE parser
- Model metadata tests with improved field mapping validation
- Documentation across provider guides and API references

### Fixed

- **Bedrock streaming binary protocol** (AWS Event Stream) encoding in fixtures
  - Removed redundant "decoded" field that caused Jason.EncodeError
  - Fixtures now only store "b64" field for binary protocols (contains invalid UTF-8)
- **Bedrock thinking parameter removal** for forced tool_choice scenarios
  - Extended thinking incompatible with object generation fixed via post-processing
  - Thinking parameter correctly removed when incompatible with forced tool_choice
- **Bedrock tool round-trip conversations** now work correctly
  - Extracts stub tools from messages when tools required but not provided
  - Bedrock requires tools definition even for multi-turn tool conversations
  - Supports both ReqLLM.Tool structs and minimal stub tools for validation
- **Bedrock usage metrics** now include all required fields
  - Meta Llama models provide complete usage data (cached_tokens, reasoning_tokens)
  - OpenAI OSS models provide complete usage data
- Model compatibility task now uses `normalize_model_id` callback for registry lookups
  - Fixes inference profile ID recognition (e.g., global.anthropic.claude-sonnet-4-5)
- Missing `:compiled_schema` in object streaming options (KeyError fix across all providers)
- Nil tool names in streaming deltas now properly guarded
- Tool.Inspect protocol crash when inspecting tools with JSON Schema (map) parameter schemas
- **HTTP/2 flow control bug** with large request bodies (>64KB)
  - Changed default Finch pool from [:http2, :http1] to [:http1]
  - Added validation to prevent HTTP/2 with large payloads
- ArgumentError when retry function returns `{:delay, ms}` (Req 0.5.15+ compatibility)
  - Removed conflicting `retry_delay` option from `ReqLLM.Step.Retry.attach/1`
- Validation errors now use correct Error struct fields (reason vs errors)
- Dialyzer type mismatches in decode_response/2

### Changed

- **Removed JidoKeys dependency**, simplified to dotenvy for .env file loading
  - API keys now loaded from .env files at startup
  - Precedence: runtime options > application config > system environment
- **Upgraded dependencies:**
  - ex_aws_auth from ~> 1.0 to ~> 1.3
  - ex_doc from 0.38.4 to 0.39.1
  - zoi from 0.7.4 to 0.8.1
  - credo to 1.7.13
- **Refactored Bedrock provider** to use modern ex_aws_auth features
  - Migrated to AWSAuth.Credentials struct for credential management
  - Replaced manual request signing with AWSAuth.Req plugin (removed ~40 lines of code)
  - Updated Finch streaming to use credential-based signing API
  - Session tokens now handled automatically by ex_aws_auth
  - Simplified STS AssumeRole implementation using credential-based API
- Comprehensive test timeout increased from 180s to 300s for slow models (e.g., Claude Opus 4.1)
- Formatter line length standardized to 98 characters
- Quokka dependency pinned to specific version (2.11.2)

### Removed

- Outdated test fixtures for deprecated models (Claude 3.5 Sonnet variants, OpenAI o1/o3/o4 variants)
- Over 85,000 lines of stale fixture data cleaned up

### Infrastructure

- CI workflow updates for Elixir 1.18/1.19 on OTP 27/28
- Enhanced GitHub Actions configuration with explicit version matrix
- Added hex.pm best practices (changelog link, module grouping)
- Improved documentation organization with provider-specific guides
- Added Claude Opus 4.1 (us.anthropic.claude-opus-4-1-20250805-v1:0) to ModelMatrix

## [1.0.0-rc.7] - 2025-10-16

### Changed

- Updated Elixir compatibility to support 1.19
- Replaced aws_auth GitHub dependency with ex_aws_auth from Hex for Hex publishing compatibility
- Enhanced Dialyzer configuration with ignore_warnings option
- Refactored request struct creation across providers using Req.new/2

### Added

- Provider normalize_model_id/1 callback for model identifier normalization
- Amazon Bedrock support for inference profiles with region prefix stripping
- ToolCall helper functions: function_name/1, json_arguments/1, arguments/1, find_args/2
- New model definitions for Alibaba, Fireworks AI, GitHub Models, Moonshot AI, and Zhipu AI
- Claude Haiku 4.5 model entries across multiple providers

### Refactored

- Removed normalization layer for tool calls, using ReqLLM.ToolCall structs directly
- Simplified tool call extraction using find_args/2 across provider modules

## [1.0.0-rc.6] - 2025-02-15

### Added

- AWS Bedrock provider with streaming support and multi-model capabilities
  - Anthropic Claude models with native API delegation
  - OpenAI OSS models (gpt-oss-120b, gpt-oss-20b)
  - Meta Llama models with native prompt formatting
  - AWS Event Stream binary protocol parser
  - AWS Signature V4 authentication (OTP 27 compatible)
  - Converse API for unified tool calling across all Bedrock models
  - AWS STS AssumeRole support for temporary credentials
  - Extended thinking support via additionalModelRequestFields
  - Cross-region inference profiles (global prefix)
- Z.AI provider with standard and coding endpoints
  - GLM-4.5, GLM-4.5-air, GLM-4.5-flash models (131K context)
  - GLM-4.6 (204K context, improved reasoning)
  - GLM-4.5v (vision model with image/video support)
  - Tool calling and reasoning capabilities
  - Separate endpoints for general chat and coding tasks
- ToolCall struct for standardized tool call representation
- Context.append/2 and Context.prepend/2 methods replacing push\_\* methods
- Comprehensive example scripts (embeddings, context reuse, reasoning tokens, multimodal)
- StreamServer support for raw fixture generation and reasoning token tracking

### Enhanced

- Google provider with native responseSchema for structured output
- Google file/video attachment support with OpenAI-formatted data URIs
- XAI provider with improved structured output test coverage
- OpenRouter and Google model fixture coverage
- Model compatibility task with migrate and failed_only options
- Context handling to align with OpenAI's tool_calls API format
- Tool result encoding for multi-turn conversations across all providers
- max_tokens extraction from Model.new/3 to respect model defaults
- Error handling for metadata-only providers with structured Splode errors
- Provider implementations to delegate to shared helper functions

### Fixed

- get_provider/1 returning {:ok, nil} for metadata-only providers
- Anthropic tool result encoding for multi-turn conversations (transform :tool role to :user)
- Google structured output using native responseSchema without additionalProperties
- Z.AI provider timeout and reasoning token handling
- max_tokens not being respected from Model.new/3 across providers
- File/video attachment support in Google provider (regression from b699102)
- Tool call structure in Bedrock tests with compiler warnings
- Model ID normalization with dashes to underscores

### Changed

- Tool call architecture: tool calls now stored in message.tool_calls field instead of content parts
- Tool result architecture: tool results use message.tool_call_id for correlation
- Context API: replaced push_user/push_assistant/push_system with append/prepend
- Streaming protocol: pluggable architecture via parse_stream_protocol/2 callback
- Provider implementations: improved delegation patterns reducing code duplication

### Infrastructure

- Massive test fixture update across all providers
- Enhanced fixture system with amazon_bedrock provider mapping
- Sanitized credential handling in fixtures (x-amz-security-token)
- :xmerl added to extra_applications for STS XML parsing
- Documentation and template improvements

## [1.0.0-rc.5] - 2025-02-07

### Added

- New Cerebras provider implementation with OpenAI-compatible Chat Completions API
- Context.from_json/1 for JSON deserialization enabling round-trip serialization
- Schema `:in` type support for enums, ranges, and MapSets with JSON Schema generation
- Embed and embed_many functions supporting single and multiple text inputs
- New reasoning controls: `reasoning_effort`, `thinking_visibility`, and `reasoning_token_budget`
- Usage tracking for cached_tokens and reasoning_tokens across all providers
- Model compatibility validation task (`mix mc`) with fixture-based testing
- URL sanitization in transcripts to redact sensitive parameters (api_key, token)
- Comprehensive example scripts for embeddings and multimodal analysis

### Enhanced

- Major coverage test refresh with extensive fixture updates across all providers
- Unified generation options schema delegating to ReqLLM.Provider.Options
- Provider response handling with better error messages and compatibility
- Google Gemini streaming reliability and thinking budget support for 2.5 models
- OpenAI provider with structured output response_format option and legacy tool call decoding
- Groq provider with improved streaming and state management
- Model synchronization and compatibility testing infrastructure
- Documentation with expanded getting-started.livemd guide and fixes.md

### Fixed

- Legacy parameter normalization (stop_sequences, thinking, reasoning)
- Google provider usage calculation handling missing candidatesTokenCount
- OpenAI response handling for structured output and reasoning models
- Groq encoding and streaming response handling
- Timeout issues in model compatibility testing
- String splitting for model names using parts: 2 for consistent pattern extraction

### Changed

- Deprecated parameters removed from provider implementations for cleaner code
- Model compatibility task output format streamlined
- Supported models state management with last recorded timestamps
- Sample models configuration replacing test model references

### Infrastructure

- Added Plug dependency for testing
- Dev tooling with tidewave for project_eval in dev scenarios
- Enhanced .gitignore to track script files
- Model prefix matching in compatibility task for improved filtering

## [1.0.0-rc.4] - 2025-01-29

### Added

- Claude 4.5 model support
- Tool call support for Google Gemini provider
- Cost calculation to Response.usage()
- Unified `mix req_llm.gen` command consolidating all AI generation tasks

### Enhanced

- Major streaming refactor from Req to Finch for production stability
- Documentation for provider architecture and streaming requests

### Fixed

- Streaming race condition causing BadMapError
- max_tokens translation to max_completion_tokens for OpenAI reasoning models
- Google Gemini role conversion ('assistant' to 'model')
- req_http_options passing to Req
- Context.Codec encoding of tool_calls field for OpenAI compatibility

### Removed

- Context.Codec and Response.Codec protocols (architectural simplification)

## [1.0.0-rc.3] - 2025-01-22

### Added

- New Mix tasks for local testing and exploration:
  - generate_text, generate_object (structured output), and stream_object
  - All tasks support --log-level and --debug-dir for easier debugging; stream_text gains debug logging
- New providers: Alibaba (China) and Z.AI Coding Plan
- Google provider:
  - File content parts support (binary uploads via base64) for improved multimodal inputs
  - Added Gemini Embedding 001 support
- Model capability discovery and validation to catch unsupported features early (e.g., streaming, tools, structured output, embeddings)
- Streaming utilities to capture raw SSE chunks and save streaming fixtures
- Schema validation utilities for structured outputs with clearer, actionable errors

### Enhanced

- Major provider refactor to a unified, codec-based architecture
  - More consistent request/response handling across providers and improved alignment with OpenAI semantics
- Streaming reliability and performance improvements (better SSE parsing and handling)
- Centralized model metadata handling for more accurate capabilities and configuration
- Error handling and logging across the library for clearer diagnostics and easier troubleshooting
- Embedding flow robustness and coverage

### Fixed

- More informative errors on invalid/partial provider responses and schema mismatches
- Stability improvements in streaming and fixture handling across providers

### Changed

- jido_keys is now a required dependency (installed transitively; no code changes expected for most users)
- Logging warnings standardized to Logger.warning

### Internal

- Testing infrastructure overhaul:
  - New timing-aware LLMFixture system, richer streaming/object/tool-calling fixtures, and broader provider coverage
  - Fake API key support for safer, more reliable test runs

### Notes

- No public API-breaking changes are expected; upgrades should be seamless for most users

## [1.0.0-rc.2] - 2025-01-15

### Added

- Model metadata guide with comprehensive documentation for managing AI model information
- Local patching system for model synchronization, allowing custom model metadata overrides
- `.env.example` file to guide API key setup and configuration
- GitHub configuration files for automated dependency management and issue tracking
- Test coverage reporting with ExCoveralls integration
- Centralized `ReqLLM.Keys` module for unified API key management with clear precedence order

### Fixed

- **BREAKING**: Bang methods (`generate_text!/3`, `stream_text!/3`, `generate_object!/4`) now return naked values instead of `{:ok, result}` tuples ([#9](https://github.com/agentjido/req_llm/pull/9))
- OpenAI o1 and o3 model parameter translation - automatic conversion of `max_tokens` to `max_completion_tokens` and removal of unsupported `temperature` parameter ([#8](https://github.com/agentjido/req_llm/issues/8), [#11](https://github.com/agentjido/req_llm/pull/11))
- Mix task for streaming text updated to work with new bang method patterns
- Embedding method documentation updated from `generate_embeddings/2` to `embed_many/2`

### Enhanced

- Provider architecture with new `translate_options/3` callback for model-specific parameter handling
- API key management system with centralized `ReqLLM.Keys` module supporting multiple source precedence
- Documentation across README.md, guides, and usage-rules.md for improved clarity and accuracy
- GitHub workflow and dependency management with Dependabot automation
- Response decoder modules streamlined by removing unused Model aliases
- Mix.exs configuration with improved Dialyzer setup and dependency organization

### Technical Improvements

- Added validation for conflicting provider parameters with `validate_mutex!/3`
- Enhanced error handling for unsupported parameter translations
- Comprehensive test coverage for new translation functionality
- Model synchronization with local patch merge capabilities
- Improved documentation structure and formatting across all guides

### Infrastructure

- Weekly automated dependency updates via Dependabot
- Standardized pull request and issue templates
- Enhanced CI workflow with streamlined checks
- Test coverage configuration and reporting setup

## [1.0.0-rc.1] - 2025-01-13

### Added

- First public release candidate
- Composable plugin architecture built on Req
- Support for 45+ providers and 665+ models via models.dev sync
- Typed data structures for all API interactions
- Dual API layers: low-level Req plugin and high-level helpers
- Built-in streaming support with typed StreamChunk responses
- Automatic usage and cost tracking
- Anthropic and OpenAI provider implementations
- Context Codec protocol for provider wire format conversion
- JidoKeys integration for secure API key management
- Comprehensive test matrix with fixture and live testing support
- Tool calling capabilities
- Embeddings generation support (OpenAI)
- Structured data generation with schema validation
- Extensive documentation and guides

### Features

- `ReqLLM.generate_text/3` and `generate_text!/3` for text generation
- `ReqLLM.stream_text/3` and `stream_text!/3` for streaming responses
- `ReqLLM.generate_object/4` and `generate_object!/4` for structured output
- Embedding generation support
- Low-level Req plugin integration
- Provider-agnostic model specification with "provider:model" syntax
- Automatic model metadata loading and cost calculation
- Tool definition and execution framework
- Message and content part builders
- Usage statistics and cost tracking on all responses

### Technical

- Elixir ~> 1.15 compatibility
- OTP 24+ support
- Apache-2.0 license
- Comprehensive documentation with HexDocs
- Quality tooling with Dialyzer, Credo, and formatter
- LiveFixture testing framework for API mocking

[1.0.0]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0
[1.0.0-rc.8]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.8
[1.0.0-rc.7]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.7
[1.0.0-rc.6]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.6
[1.0.0-rc.5]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.5
[1.0.0-rc.4]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.4
[1.0.0-rc.3]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.3
[1.0.0-rc.2]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.2
[1.0.0-rc.1]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.1
