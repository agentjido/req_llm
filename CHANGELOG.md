# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Structured output (`:object` operation) support for AWS Bedrock provider
  - Bedrock Anthropic sub-provider using tool-calling approach
  - Bedrock Converse API for unified structured output across all models
  - Bedrock OpenAI sub-provider (gpt-oss models)
- Configurable metadata timeout for streaming operations with `:metadata_timeout` option (default: 300,000ms)
- Application-level configuration support for `:metadata_timeout`

### Fixed

- Metadata collection timeout errors on large documents with long processing times
- Bedrock streaming now works correctly (fixed deprecated function capture syntax)
- Tool.Inspect protocol crash when inspecting tools with JSON Schema (map) parameter schemas

### Changed

- Upgraded ex_aws_auth dependency from ~> 1.0 to ~> 1.3
- Refactored Bedrock provider to use modern ex_aws_auth features
  - Migrated to AWSAuth.Credentials struct for credential management
  - Replaced manual Req request signing with AWSAuth.Req plugin (removed ~40 lines of code)
  - Updated Finch streaming to use credential-based signing API
  - Session tokens now handled automatically by ex_aws_auth
- Simplified STS AssumeRole implementation using credential-based API

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
- `ReqLLM.generate_embeddings/3` for vector embeddings
- `ReqLLM.run/3` for low-level Req plugin integration
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

[1.0.0-rc.6]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.6
[1.0.0-rc.5]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.5
[1.0.0-rc.4]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.4
[1.0.0-rc.3]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.3
[1.0.0-rc.2]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.2
[1.0.0-rc.1]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0-rc.1
