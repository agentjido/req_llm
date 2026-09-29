# OpenAI DevDay rollout: September 29, 2026

The full rollout requires user review before shipment. Do not merge or release before approval.

## Direct sources

- [DevDay announcement list and Decisions preview](https://openai.com/index/devday-2026-recap/)
- [GPT-6.1 Sol model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [Model migration guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
- [Multi-agent request and output contract](https://developers.openai.com/api/docs/guides/responses-multi-agent)
- [Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode)
- [Agents API computer use](https://developers.openai.com/api/docs/guides/agents-api/tools/computer-use)

## Review checklist

- [x] Recognize Sol 6.1, validate its required reasoning efforts, and retain Sol and Luna sampling at effort none.
- [x] Route explicit model specifications to Responses when wire metadata is absent.
- [x] Document Fast and Ultrafast tiers.
- [x] Add multi-agent configuration and beta headers for HTTP, SSE, and WebSocket.
- [x] Keep agent identity on tool calls, stream chunks, and raw history.
- [x] Keep root text in the final answer and overall usage totals.
- [x] Replay encrypted agent messages, hosted calls, and per-agent compaction items.
- [x] Return child-agent function results with the original call ID.
- [x] Reject explicit compact, reasoning summaries, and max_tool_calls in multi-agent mode.
- [x] Verify Image 2.5 quality values and catalog routing.
- [x] Verify cache diagnostic request options and buffered and streamed results.
- [x] Review voice changes and define separate session-client work.
- [x] Defer Decisions to [issue #1062](https://github.com/agentjido/req_llm/issues/1062), as requested by the user.
- [x] Run tests and quality checks, and prepare separate local commits.
- [ ] User review and explicit approval to ship. This is the shipment gate.

## Decisions API: deferred contract

OpenAI confirms a Luna-based API with text or image context and finite predefined answers. It is in limited preview. Public searches have not found its technical contract.

The implementation requires official endpoint and authentication details, model identifiers, input and output schemas, error behavior, limits, access requirements, and pricing. Streaming and batching must be checked rather than assumed. Keep the existing OpenRouter decisions contract separate. Do not present ordinary structured generation as OpenAI Decisions support.

This missing contract does not prevent the independent model and Responses work. The user approved shipment without Decisions support on September 29, 2026. Issue #1062 tracks the remaining work.

## Separate proposed integrations

These proposals are outside the current generation adapter changes.

### Agents API computer use

Build a separate session client with create, run, continue, cancel, and close operations. Keep session IDs and required-action events. Expose browser approval and authentication events to the caller. Keep browser access decisions with the caller. Add tests for approval, rejection, authentication, continuation, cancellation, and stream recovery. Keep native event data available for the agent runtime.

Source: [computer use](https://developers.openai.com/api/docs/guides/agents-api/tools/computer-use).

### Bedrock Managed Agents

Build an AWS session adapter after verifying endpoint, signing, region, identity, and event contracts. Reuse AWS authentication code only where the contract matches. Add session continuation and cancellation, event decoding, required-action handling, and tests for signing, region selection, errors, and reconnection. Do not add session behavior to the existing Bedrock model-name mapping.

Source: [Bedrock Managed Agents](https://developers.openai.com/api/docs/guides/agents-api/bedrock-managed-agents).

### GPT Live

Build a Live session transport with bidirectional audio, interruption handling, and backend-agent delegation. Add per-second session accounting, with backend model and tool usage recorded separately. Test voice events, interruption, duration accounting, and connection loss. The llmdb rollout records the price and blocks incorrect text and Realtime routes. It does not add a Live client to ReqLLM.

Source: [GPT Live 1](https://developers.openai.com/api/docs/models/gpt-live-1).

## Validation

The full ReqLLM suite passed 4,792 tests, with 11 skipped and 213 excluded. After adding hosted event preservation and completion checks, 82 focused image, Astra, multi-agent, and cache tests passed. `mix quality` passed after the code change. The cross-repository script prepared Sol 6.1 Responses and Image 2.5 Images requests without sending them.

Run the integration check with `MIX_ENV=test mix run scripts/check_devday_catalog.exs /absolute/path/to/llmdb/priv/llm_db/snapshot.json`. Sol 6.1 catalog lookup needs the new llmdb data. Explicit model maps are supported before that data ships.

The tests use mock requests and documented response shapes. No live beta API request was sent. Native live WebSocket tool injection requires caller handling through the session interface; the normal continuation path returns tool results after response completion.

## September review

Image 2.5 already accepts xhigh and max quality in ReqLLM. Catalog routing and prices needed correction in llmdb. Cache diagnostics use comparison_response_id in prompt_cache_options and remain in provider_meta for buffered and completed streamed Responses results. Diagnostic token estimates do not alter billable usage.

Source: [cache diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).

The September 25 image encoding fix is a server change. Re-run application image evaluations after release; no different client encoding is documented in the [API changelog](https://developers.openai.com/api/docs/changelog).
