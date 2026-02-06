# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- changelog -->

## [v1.5.1](https://github.com/agentjido/req_llm/compare/v1.5.0...v1.5.1) (2026-02-04)




### Bug Fixes:

* Return metadata for incomplete responses (#403) by Tom Duffield

* include metadata with incomplete responses by Tom Duffield

* add missing verbosity documention for openai by Tom Duffield

* improve streaming stability with finch client fixes (#400) by mikehostetler

* req_llm: improve streaming stability with finch client fixes by mikehostetler

* move changelog marker so git_ops inserts in correct position by mikehostetler

### Refactoring:

* Centralize text extraction and update dependencies by mikehostetler

## [v1.5.0](https://github.com/agentjido/req_llm/compare/v1.4.1...v1.5.0) (2026-02-01)

### Features:

* add xAI image generation support (#397) by Victor

* add xai image generation support by Victor

### Bug Fixes:

* remove unsupported-option warnings by Victor

## [1.4.1] - 2026-01-31

### Added

- Tool call normalization helpers: `ToolCall.from_map/1` and `ToolCall.to_map/1` for consistent tool-call handling across providers (#396)

### Fixed

- Made `git_ops` configuration available outside dev-only config so CI releases work correctly

## [1.4.0] - 2026-01-30

### Added

- Comprehensive usage and billing infrastructure with richer usage/cost reporting (#371)
- Reasoning cost breakdown with `reasoning_cost` field in cost calculations (#394)
- OpenRouter enhancements:
  - `openrouter_usage` and `openrouter_plugins` provider options (#393)
  - Native JSON schema structured output support (#374)
- Google provider options:
  - `google_url_context` for URL grounding (#392)
  - `google_auth_header` option for streaming requests (#382)
- OpenAI improvements:
  - Configurable strict mode for JSON schema validation (#368)
  - Verbosity support for reasoning models (#354)
- Cohere Embeddings on Bedrock (#365)
- Structured and multimodal tool outputs (#357)
- Model `base_url` override in model configuration (#366)

### Changed

- Replaced TypedStruct with Zoi schemas for data structures (#376)

### Fixed

- Image-only attachments validation for OpenAI and xAI (#389)
- `translate_options` changes now preserved in `provider_options` (#381)
- StreamServer termination handled gracefully in FinchClient (#379)
- Anthropic schema constraints stripped when unsupported (#378)
- `api_key` added to internal keys preventing leakage (#355)

## [1.3.0] - 2026-01-21

### Added

- **New Providers:**
  - Zenmux provider and playground (#342)
  - vLLM provider for self-hosted OpenAI-compatible models (#202)
  - Venice AI provider (#200)
  - Azure DeepSeek model support (#254)
- Azure Foundry Bearer token authentication (#338)
- Z.ai thinking parameter support (#303)
- OpenAI `service_tier` option (#321)
- OpenAI wire protocol routing (#318)
- Context and streaming improvements:
  - `Context.normalize/1` extended for `tool_calls` and tool result messages (#313)
  - Preserve `reasoning_details` during streaming tool-call round-trips (#300)
  - `StreamResponse.classify/1` and `Response.Stream.summarize/1` (#311)
- Google file URI support for `image_url` content parts (#339)
- Reasoning signatures retainment (#344)
- `generate_object` now accepts map input (#301)
- OpenRouter support for google/gemini-3-flash-preview (#298)

### Fixed

- Anthropic `encrypted?` flag in reasoning details extraction
- Anthropic cache token handling for API semantics (#316)
- Missing reasoning levels (#332)
- Google Gemini thinking tokens in cost calculation (#336)
- Hyphenated tool names for MCP server compatibility (#323)
- Azure `provider_options` validation and ResponsesAPI `finish_reason` parsing (#266)
- Cache token extraction and cost calculation (#309)
- JSON arrays for JsonSchema and Gemini 3 schema calls (#310)
- Gemini `generate_object` always sets `responseMimeType` (#299)
- Z.ai `zai_coding_plan` provider support (#347)
- Ecosystem conflicts with typedstruct naming (#315)

## [1.2.0] - 2025-12-22

### Added

- Image generation support (#293)
- Anthropic web search support for models (#292)
- OpenRouter first-class `reasoning_details` support (#267)
- Google Vertex AI:
  - Inline JSON credentials support (#260)
  - Google Search grounding for Gemini models (#284)
- Anthropic message caching for conversation prefixes (#281)
- `load_dotenv` config option to control .env file loading (#287)

### Changed

- Response assembly unified across providers (#274)
- Streaming preserves grounding metadata (#278)

### Fixed

- Streaming errors propagate to `process_stream` result (#286)
- Debug URLs sanitized when streaming with Google (#279)
- Functional tool streaming response bug (#263)

## [1.1.0] - 2025-12-21

### Added

- **New Providers:**
  - Azure OpenAI provider (#245)
  - Google Vertex Gemini support
  - Google Vertex AI Anthropic provider (#217)
- OAuth2 token caching for Google Vertex AI (#174)
- Google Context Caching for Gemini models (#193)
- Amazon Bedrock `service_tier` support (#225)
- OpenAI / Responses API:
  - `tool_choice: required` support (#215)
  - Reasoning effort support (#244)
- Model capability helper functions (#222)
- `StreamResponse.process_stream/2` for real-time callbacks (#178)
- Custom providers defined outside req_llm (#201)
- llm_db integration for model metadata (#212)
- Credential fallback for fixture recording (#218)

### Changed

- Data structures migrated to typedstruct (#256)
- Streaming metadata access made reusable (#206)
- Anthropic structured output modes enhanced (#223)

### Fixed

- Default timeout increased for OpenAI reasoning models (#252)
- Consecutive tool results merged into single user message (#250)
- `.env` loading respects existing env vars (#249)
- Responses API tool encoding uses flat structure (#247)
- `finish_reason` captured correctly when streaming (#241)
- OpenAI Responses context replay and Anthropic structured output decode (#228)
- StreamResponse context merging (#224)
- `tool_budget_for` pattern match regression from LLMDB integration (#221)
- `reasoning_overlay` pattern match for llmdb structure (#219)
- Missing `api_key` in Anthropic extra options (#216)
- Typespec for object generation to allow Zoi schemas (#208)
- Cerebras strict mode handling (#180)
- JSV schema validation preserves original data types (#173)
- Cached token extraction from Google API responses (#192)

## [1.0.0] - 2025-11-02

First production-ready release of ReqLLM.

### Added

- **Google Vertex AI provider** with comprehensive Claude 4.x support
  - OAuth2 authentication with service accounts
  - Full Claude model support (Haiku 4.5, Sonnet 4.5, Opus 4.1)
  - Extended thinking and prompt caching capabilities
- **AWS Bedrock inference profile models** with complete fixture coverage
  - Anthropic Claude inference profiles
  - OpenAI OSS models
  - Meta Llama inference profiles
  - Cohere Command R models
- **Provider base URL override** capability via application config
- AWS Bedrock API key authentication (introduced by AWS in July 2025)
- Context tools persistence for AWS Bedrock multi-turn conversations
- Schema map-subtyped list support for complex nested structures

### Changed

- Google provider uses v1beta API as default version
- Streaming protocol callback renamed from `decode_sse_event` to `decode_stream_event`

### Fixed

- Groq UTF-8 boundary handling in streaming responses
- Schema boolean encoding preventing invalid string coercion
- AWS Bedrock Anthropic inference profile model ID preservation
- AWS Bedrock Converse API usage field parsing
- AWS Bedrock model ID normalization for metadata lookup

[Unreleased]: https://github.com/agentjido/req_llm/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/agentjido/req_llm/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/agentjido/req_llm/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/agentjido/req_llm/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/agentjido/req_llm/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/agentjido/req_llm/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/agentjido/req_llm/releases/tag/v1.0.0