# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- changelog -->

## [v1.11.0](https://github.com/agentjido/req_llm/compare/v1.10.0...v1.11.0) (2026-05-01)




### Features:

* openrouter: support session_id option by mikehostetler

* support reusable Responses WebSocket sessions (#663) by Danila Poyarkov

* azure: support Kimi family on Azure AI Foundry by Senthil

* openai: add logprobs support for chat completions by Jad Tarabay

* schema: support {:or, [type, nil]} for nullable JSON Schema types (#637) by Gustavo Honorato

* anthropic: signal tool execution failures with is_error (#625) by BlueHotDog

* add cost usage support for rerank (#622) by sezaru

* azure: support Azure OpenAI v1 GA API (no api-version) (#623) by neilberkman

### Bug Fixes:

* stream: emit terminal :error chunk for SSE error events from OpenAI-compatible providers (#661) by RamXX

* deepseek: inject reasoning_content to all assistant messages (#660) by Bill Huang

* openai: decode completed responses stream items (#662) by Itay Adler

* openai: disable response storage for codex models by Itay Adler

* fix google gemini token calculation by mikehostetler

* encode thinking content parts as reasoning_content for OpenAI-compatible providers (#647) by Senthil

* anthropic: reject trailing assistant object contexts by mikehostetler

* openrouter: support embeddings by mikehostetler

* google: preserve Gemini SSE finish reasons by ycastorium

* openai: preserve responses assistant phases (#636) by mikehostetler

* bedrock: preserve native Claude thinking signatures by mikehostetler

* vertex: preserve Claude thinking signatures in streams by mikehostetler

* azure: preserve Claude thinking signatures in streams by mikehostetler

* anthropic: preserve streamed thinking blocks (#627) by mikehostetler

* openai: encode multimodal tool outputs in Responses API (#624) by BlueHotDog

* include embedding cost metadata (#621) by mikehostetler

* openai: dedupe Responses API commentary and final answer (#618) by Zack

### Performance:

* streaming: adopt server_sent_events 1.0 parser (#649) by mikehostetler

## [v1.10.0](https://github.com/agentjido/req_llm/compare/v1.9.0...v1.10.0) (2026-04-17)




### Features:

* schema: apply property ordering at wire encoding for non-Google providers (#600) by mhsdef

* schema: preserve property ordering in generated JSON schema (#599) by mikehostetler

* forward parallel_tool_calls to Responses API body (#595) by BlueHotDog

* openai: add explicit ollama auth marker (#594) by mikehostetler

* openai: add `store` provider option for ZDR orgs, allow PDFs for Responses API models (#584) by mhsdef

* Allow redaction of message content when inspecting Context struct (#590) by Shane Howley

* google_vertex: add label support to vertex (#587) by thiagomajesk

### Bug Fixes:

* http: preserve custom finch in sync requests (#617) by mikehostetler

* openai_codex: omit previous_response_id on tool resume (#613) by nsi-inco

* azure: route responses models correctly by neilberkman

* openai: include summary field in reasoning block encoding by mhsdef

* normalize provider tool choice handling and harden tool call decoding (#598) by Zack

* streaming: return structured stream timeouts (#592) by mikehostetler

* anthropic: handle malformed tool arguments gracefully (#586) by BlueHotDog

* bedrock: preserve inference profile prefix in API URLs (#578) by neilberkman

## [v1.9.0](https://github.com/agentjido/req_llm/compare/v1.8.0...v1.9.0) (2026-03-27)




### Features:

* add mistral provider (#554) by mikehostetler

* add `thinkingLevel` support to Google provider (#565) by Tom Taylor

* add `thinkingLevel` support to Google provider by Tom Taylor

* add `finch_request_adapter` config to modify streaming requests (#566) by johantell

* add FinchRequestAdapter for config-level streaming request transforms by johantell

* add OpenAI websocket streaming and realtime support (#559) by mikehostetler

* allow unknown models with warnings instead of errors (#561) by dl-alexandre

* add reranking API with batch processing (#553) by mikehostetler

* add OpenTelemetry bridge and telemetry stubs (#548) by mikehostetler

* add video URL message support (#549) by mikehostetler

* support Anthropic native tool options (#547) by mikehostetler

* support Anthropic native tool options by mikehostetler

* add Google Imagen image generation support (#550) by mikehostetler

* generation: repair lightly malformed structured JSON (#543) by mikehostetler

* add available model discovery (#544) by mikehostetler

* add application-layer cache hooks (#541) by mikehostetler

* generation: add application cache hooks by mikehostetler

* rate limit retry (429) and custom headers for streaming (#537) by dl-alexandre

* pass custom headers to Finch streaming requests by dl-alexandre

* Add Deepseek support (#538) by Luis Ezcurdia

### Bug Fixes:

* openai: retrieve structured output from tool call (#572) by Robin Verton

* openai: retrieve structured output from tool call by Robin Verton

* openai: validate tool-call structured output by Robin Verton

* track google thinking levels in telemetry by Tom Taylor

* restore streaming fixture recording functionality (#560) by dl-alexandre

* add Google long-context pricing tiers (#546) by mikehostetler

* Allow model specific base_url for streaming responses (#562) by meanderingstream

* Support json schema usage for gemini 3.1 (#563) by Akash Khan

* preserve Anthropic tool formatter shape by mikehostetler

* default GPT-4o models to OpenAI Responses API (#552) by mikehostetler

* zero app-cache usage on response hits (#542) by mikehostetler

* usage: zero app cache hit usage by mikehostetler

* remove dead cache provider meta fallback by mikehostetler

* support multiple system messages (#545) by mikehostetler

* register azure request options from defaults by mikehostetler

* schema: preserve doc option in nested {:map, opts} fields by dl-alexandre

* openai: validate nested object schemas with string keys by dl-alexandre

* streaming retry accumulator and 429 detection bugs by dl-alexandre

* streaming: retry 429 responses and honor map headers by dl-alexandre

* streaming: resolve 429 retry dialyzer warning by dl-alexandre

* streaming: restore 429 failure callback order by dl-alexandre

* bedrock: drop empty messages in Converse encoder (#540) by Julian Scheid

### Refactoring:

* simplify transient streaming logs by mikehostetler

## [v1.8.0](https://github.com/agentjido/req_llm/compare/v1.7.1...v1.8.0) (2026-03-23)




### Features:

* add web_fetch server tool support by Tonyhaenn

* add oauth-backed OpenAI Codex routing (#513) by l3wi

* openai: add oauth-backed codex routing by l3wi

* add native request and reasoning telemetry (#515) by mikehostetler

* add native request and reasoning telemetry by mikehostetler

* add cross-provider tool call ID compatibility (#417) by mikehostetler

* add cross-provider tool call id compatibility by mikehostetler

### Bug Fixes:

* honor req_llm load_dotenv when starting llm_db (#536) by mikehostetler

* honor req_llm load_dotenv when starting llm_db by mikehostetler

* include llm_db in dialyzer plt apps by mikehostetler

* openai: validate nested object schemas with string keys (#533) by dl-alexandre

* bedrock: filter empty text blocks in Converse (#534) by Julian Scheid

* schema: preserve doc option in nested {:map, opts} fields (#532) by dl-alexandre

* retry transient streaming transport failures (#531) by mikehostetler

* preserve google embedding usage metadata (#530) by mikehostetler

* break azure anthropic xref cycle (#529) by mikehostetler

* make livebook validation deterministic by dl-alexandre

* format livebook parse errors from metadata by dl-alexandre

* remove unsupported outputMimeType and add response_modalities foâ¦ (#517) by mrdotb

* remove unsupported outputMimeType and add response_modalities for Google images by mrdotb

* normalize Gemini response modalities by mrdotb

* gate Anthropic server tools behind beta headers by Tonyhaenn

* default Codex streaming auth to oauth by l3wi

* merge consecutive same-role entries in Gemini message encoding (#525) by paulorumor

* prevent Inspect.ReqLLM.Context crash on Logger depth truncation (#519) by Edgar Gomes

* azure: add Grok to known model families (#518) by shelvick

* azure: add Grok to known model families by shelvick

* azure: add Grok to OpenAI-compatible prefix lists and add reasoning_token_budget by shelvick

* support image content in Bedrock tool results (#516) by Julian Scheid

* OpenAI content encoding for thinking parts and empty arrays (#428) by laudney

* restore telemetry raw payload capture (#520) by mikehostetler

* restore telemetry raw payload capture by mikehostetler

* resolve CI regressions for telemetry by mikehostetler

* harden telemetry reasoning normalization by mikehostetler

* update tool call IDs and timestamps in compatibility JSON fixtures by mikehostetler

* accept map-based vertex model metadata by mikehostetler

* google: strip atom-keyed forbidden schema fields (#504) by pcharbon70

* remove impossible role == :tool checks (#508) by Barna Kovacs

* remove redundant fallback for reasoning tokens in normalize (#507) by Barna Kovacs

### Refactoring:

* only inherit llm_db load_dotenv when unset by mikehostetler

## [v1.7.1](https://github.com/agentjido/req_llm/compare/v1.7.0...v1.7.1) (2026-03-14)




### Bug Fixes:

* make image tests resilient to llm_db catalog updates by mikehostetler

* preserve assistant metadata and reasoning details when normalizing loose maps (#501) by Chris Lema

* format context normalization branches by Chris Lema

## [v1.7.0](https://github.com/agentjido/req_llm/compare/v1.6.0...v1.7.0) (2026-03-14)




### Features:

* normalize and document inline model specs (#500) by mikehostetler

* normalize and document inline model specs by mikehostetler

* add Alibaba Cloud Bailian (DashScope) provider (#470) by Steven Holdsworth

* auth: support OAuth tokens and codex Responses routing (#478) by l3wi

* auth: support OAuth tokens and codex Responses routing by l3wi

* Uses the same Finch Pool for streaming/non-streaming (#466) by ycastorium

* Add Usage to Embeddings (#444) by ycastorium

* add response_format to Vertex AI provider schema for OpenAI-compat MaaS models (#450) by shelvick

* pass anthropic_beta through Bedrock to request body (#468) by stevehodgkiss

* add Igniter installer for automated package setup by Nickcom4

### Bug Fixes:

* remove unreachable inline model clause by mikehostetler

* honor Google image output format (#499) by mikehostetler

* emit usage for Vertex embeddings (#498) by mikehostetler

* GoogleVertex extract_gcp_credentials from provider_options (#496) by paulorumor

* streaming: propagate transport errors instead of swallowing (#491) by Julian Scheid

* streaming: propagate transport errors instead of swallowing by Julian Scheid

* move examples into nested mix project by Dave Lucia

* docs: clean up sidebar (#490) by Dave Lucia

* docs: clean up sidebar by Dave Lucia

* docs: restore public providers and usage docs by Dave Lucia

* docs: improve exdoc module grouping by Dave Lucia

* ReqLLM.Response.object returns string keys (#488) by Dave Lucia

* expose stream keepalive callbacks (#495) by mikehostetler

* clean up StreamServer processes after streaming completes (#494) by mikehostetler

* clean up stream servers after stream completion by mikehostetler

* harden stream server lifecycle cleanup by mikehostetler

* auth: honor auth_mode and string-key wire protocol by l3wi

* Fixes sse in case of server failure (#463) by ycastorium

* Fixes sse in case of server failure by ycastorium

* Adds a new termination field by ycastorium

* preserve stop finish_reason for buffered done event by ycastorium

* exclude embedding return_usage from provider transport options (#471) by mikehostetler

* normalize nested string-key tool arguments safely (#459) by mikehostetler

* tool: normalize nested string-key tool arguments by mikehostetler

* tool: normalize map keys in union and tuple types by mikehostetler

* core: remove unsafe runtime string-to-atom conversions by mikehostetler

* ReqLLM embed should use embedding schema, not generation (#446) by ycastorium

* handle API error responses in Vertex AI OpenAI-compat endpoint (#451) by shelvick

* handle API error responses in Vertex AI OpenAI-compat parse_response by shelvick

* unwrap single-element list body in OpenAICompat.parse_response by shelvick

* bedrock: update inference profile prefixes (#449) by stevehodgkiss

* stream usage normalization and accumulation (#464) by stevehodgkiss

* encode tool outputs inline in Responses API input array (#454) by austin macciola

* only add cache_control to last tool in Anthropic prompt caching (#453) by tomtrin

* remove $schema and additionalProperties recursively in to_google_format (#460) by Jhon Pedroza

* allow max_retries to be 0 to disable retries (#469) by stevehodgkiss

* omit mimeType from fileData for YouTube and extensionless URLs (#442) by Nickcom4

* omit mimeType from fileData for YouTube and extensionless URLs by Nickcom4

* google: return nil for unknown inferred mime type by Nickcom4

* strip redundant tool_choice auto from OpenRouter requests (#437) by Noah S

* strip redundant tool_choice auto from OpenRouter requests by Noah S

* widen generation function specs to match Context.normalize/2 (#441) by Nickcom4

* widen generation function specs to match Context.normalize/2 by Nickcom4

* Removes redundant validation (#448) by ycastorium

## [v1.6.0](https://github.com/agentjido/req_llm/compare/v1.5.1...v1.6.0) (2026-02-19)




### Features:

* implement #431 response classify, usage API, and tool key safety (#432) by mikehostetler

* add response classify API and harden usage/tool normalization by mikehostetler

* add igniter installer (#410) by AdwayKasture

* add embedding support to google_vertex provider (#423) by paulorumor

* enable reasoning support for DeepSeek models on Azure (#412) by shelvick

* enable reasoning support for DeepSeek models on Azure by shelvick

* Add on_tool_call callback to StreamResponse (#413) by Arjan Scherpenisse

* add OpenAI-compatible model family support for Vertex AI MaaS models (#422) by shelvick

* jido: enhance agent functionality with usage tracking and multi-turn support by mikehostetler

### Bug Fixes:

* Updating model data (#435) by Pedro Assunção

* resolve dialyzer warnings in response classify normalization by mikehostetler

* handle string finish reasons in response classify by mikehostetler

* add Gemini 3 thought_signature support for function calls (#427) by Brandon L'Europa

* Do not force strict tools for responses api (#399) by ycastorium

* use proportional estimate for inferred reasoning tokens by shelvick

* route Vertex AI MaaS models to endpoints/openapi/chat/completions (#424) by shelvick

* increase default timeout for DeepSeek and MAI-DS models on Azure (#425) by shelvick

* Azure AI Foundry auth header and API version defaults (#411) by shelvick

* remove invalid `id` field from Google functionCall serialization (#414) by paulorumor

* remove invalid `id` field from Google functionCall serialization by paulorumor

* pass strict flag through to Anthropic tool format (#415) by Edgar Gomes

* pass strict flag through to Anthropic tool format by Edgar Gomes

* pass strict flag through to Bedrock Converse tool format by Edgar Gomes

* harden ZAI thinking re-encoding and req_llm.gen model errors (#420) by mikehostetler

* harden zai thinking re-encoding and gen model validation by mikehostetler

* zai: remove unreachable encode_zai_content clauses by mikehostetler

* streaming decode for inference profile models using InvokeModel API (#406) by neilberkman

* req_llm: improve streaming stability with finch client fixes by mikehostetler

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