# OpenAI DevDay source and release review

Verified on September 29, 2026. This document covers changes relevant to llmdb and ReqLLM. The [official recap](https://openai.com/index/devday-2026-recap/) is the source for the announcement list. The technical sources below define the implementation.

## Direct sources and library work

| Item | Direct source | Release work |
| --- | --- | --- |
| GPT-6.1 Sol | [Model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [GPT-6 guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra) | Add a separate catalog record. Route tools through Responses. Validate low, medium, high, xhigh, and max effort. Preserve GPT-6 Sol. |
| Sol 6.1 pricing | [Pricing](https://developers.openai.com/api/docs/pricing) | Add short and long context rates, cache rates, service modifiers, and regional processing uplift. Test the 272,000-token boundary. |
| Astra Ultrafast | [Ultrafast guide](https://developers.openai.com/api/docs/guides/ultrafast-mode) | Add the six-times Standard price modifier and US/global processing metadata. Record current Astra availability. |
| Responses multi-agent | [Request, stream, and replay contract](https://developers.openai.com/api/docs/guides/responses-multi-agent) | Add configuration and beta headers. Keep agent identity, hosted events, root answer text, function results, encrypted history, and overall usage. |
| GPT-6 async tools | [Async tool contract](https://developers.openai.com/api/docs/guides/async-tool-calling) | Extend the existing model check to GPT-6. Reject async tools with parallel tool calls in multi-agent mode. |
| Steering and configuration updates | [Steering](https://developers.openai.com/api/docs/guides/steering), [reasoning updates](https://developers.openai.com/api/docs/guides/reasoning#change-reasoning-mid-conversation) | Extend existing GPT-6 support. Keep required effort and single-agent restrictions. |
| Decisions API | [Direct announcement](https://openai.com/index/devday-2026-recap/) | Luna-based finite answers with text/image context, in limited preview. No public technical contract was found. The user deferred support to [issue #1062](https://github.com/agentjido/req_llm/issues/1062). |
| Agents API computer use | [Computer use contract](https://developers.openai.com/api/docs/guides/agents-api/tools/computer-use) | Separate session-client proposal, with browser approvals and authentication events. |
| Bedrock Managed Agents | [OpenAI integration guide](https://developers.openai.com/api/docs/guides/agents-api/bedrock-managed-agents) | Separate AWS session-adapter proposal. |
| Private Intelligence | [Private Safety Processing](https://developers.openai.com/api/docs/guides/private-safety-processing) | PSP uses project-level storage and retention setup. This is an administrator deployment task. The reviewed guide does not require a generation request field change. Private Inference is a future preview in the recap. |

Sol 6.1 Ultrafast is coming soon. This release adds no price or eligibility claim for that future tier. See the [recap](https://openai.com/index/devday-2026-recap/).

## September changes needed for this release

The [API changelog](https://developers.openai.com/api/docs/changelog) supplies the dates. These changes are part of the compatibility review, even when they preceded DevDay.

| Date | Change | Library work |
| --- | --- | --- |
| September 8 | Image 2.5 Flare and Sunburst; higher quality settings | Correct alias and dated catalog records. Preserve text/image usage counts and apply modality rates. ReqLLM already accepts xhigh and max quality. Sources: [Flare](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare), [Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst), [Images response schema](https://github.com/openai/openai-python/blob/main/src/openai/types/images_response.py). |
| September 8 | Cache diagnostics | Verify comparison_response_id in prompt_cache_options and diagnostics in buffered and streamed provider metadata. Source: [diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics). |
| September 10 | GPT Live 1 | Record audio/text modalities and per-second session pricing. Mark the model catalog-only and block incorrect generation routes. Define separate Live-client work. Source: [model contract](https://developers.openai.com/api/docs/models/gpt-live-1). |
| September 22 | GPT-6 Sol and Luna | Keep sampling at none effort. Remove unsupported sampling at higher effort. Source: [migration guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra). |
| September 25 | Sol/Luna image encoding fix | Server change. Re-run application image evaluations after the release. No new client encoding is documented in the changelog. |

## Other announcement areas

The recap also lists dots; Codex cloud, CLI, code review, and Security Cloud; plugin extensions and discovery; Sites plugin hosting; MCP automation events; ChatGPT Space, Pages, collaborative slides, teams and shared tasks; Slack and Teams access; Meetings; shareable profiles; Sign in with ChatGPT; Pro 500; and OpenAI Marketplace. See the [complete announcement list](https://openai.com/index/devday-2026-recap/).

Scope decision: these product and plugin changes do not add a supported generation operation to this library release. Future integrations need their own contracts and review.

## Review and shipment

The [ReqLLM checklist](openai-devday-rollout.md) records tests, compatibility limits, and separate integration proposals. The llmdb worktree has its own rollout checklist.

Review both local feat/openai-devday-2026 branches before shipment. The llmdb review base is 8e5fa1f. The ReqLLM review base is 30b54901. These bases retain the existing work in each repository. No package release, snapshot publication, merge, or deployment was performed.

After approval, release the llmdb data before callers depend on new catalog lookup. Explicit ReqLLM model maps work before the new catalog ships. Decisions support is no longer a release requirement, as directed by the user.
