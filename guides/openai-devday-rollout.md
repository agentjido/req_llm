# OpenAI DevDay rollout: September 29, 2026

The full rollout requires user review before shipment. Do not merge or release before approval.

The [source and release review](openai-devday-news.md) lists relevant announcements and September changes.

## Direct sources

- [DevDay announcement list and Decisions preview](https://openai.com/index/devday-2026-recap/)
- [GPT-6.1 Sol model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [Model migration guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
- [Multi-agent request and output contract](https://developers.openai.com/api/docs/guides/responses-multi-agent)
- [Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode)
- [Agents API computer use](https://developers.openai.com/api/docs/guides/agents-api/tools/computer-use)

## Review checklist

- [x] Recognize Sol 6.1, validate its required reasoning efforts, and retain Sol and Luna sampling at effort none.
- [x] Permit documented async tools, steering, and configuration updates across GPT-6 models.
- [x] Route explicit model specifications to Responses when wire metadata is absent.
- [x] Document Fast and Ultrafast tiers.
- [x] Add multi-agent configuration and beta headers for HTTP, SSE, and WebSocket.
- [x] Keep agent identity on tool calls, stream chunks, and raw history.
- [x] Keep root text in the final answer and overall usage totals.
- [x] Replay encrypted agent messages, hosted calls, and per-agent compaction items.
- [x] Return child-agent function results with the original call ID.
- [x] Reject explicit compact, reasoning summaries, and max_tool_calls in multi-agent mode.
- [x] Verify Image 2.5 quality values and catalog routing.
- [x] Complete Image 2.5 modality token usage and billing. Buffered and streamed Images retain the split, normalization preserves it, and Billing uses the new catalog rates.
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

The full ReqLLM suite passed 4,808 tests, with 11 skipped and 213 excluded. Final focused checks passed 82 billing, normalization, image decoder, and stream tests, and 79 image and usage tests. `mix quality` passed after the final code change. The cross-repository script checked Sol 6.1 Responses routing and all four Image 2.5 records, including modality costs, without sending requests.

Run the integration check with `MIX_ENV=test mix run scripts/check_devday_catalog.exs /absolute/path/to/llmdb/priv/llm_db/snapshot.json`. Sol 6.1 catalog lookup needs the new llmdb data. Explicit model maps are supported before that data ships.

The tests use mock requests and documented response shapes. No live beta API request was sent. Native live WebSocket tool injection requires caller handling through the session interface; the normal continuation path returns tool results after response completion.

## September review

Image 2.5 already accepts xhigh and max quality in ReqLLM. Catalog routing and prices needed correction in llmdb. Cache diagnostics use comparison_response_id in prompt_cache_options and remain in provider_meta for buffered and completed streamed Responses results. Diagnostic token estimates do not alter billable usage.

Source: [cache diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).

The September 25 image encoding fix is a server change. Re-run application image evaluations after release; no different client encoding is documented in the [API changelog](https://developers.openai.com/api/docs/changelog).

## GPT-6 feature review

The current official guides apply steering and configuration updates to the GPT-6 family. Async tools support Astra and later models. The old Astra-only checks now permit Sol 6.1, Sol, and Luna. Sol and Luna configuration updates can select none; Astra and Sol 6.1 cannot. Multi-agent mode rejects async tools with parallel_tool_calls enabled. Native request maps receive the same multi-agent validation.

Sources: [async tools](https://developers.openai.com/api/docs/guides/async-tool-calling), [steering](https://developers.openai.com/api/docs/guides/steering), and [reasoning configuration updates](https://developers.openai.com/api/docs/guides/reasoning#change-reasoning-mid-conversation).

The final GPT-6 family, multi-agent, and Responses checks passed 210 tests. The transport checks passed 207 tests.

## Image billing validation

The official SDK schema reports input_tokens_details.text_tokens and image_tokens, and optional output_tokens_details. ReqLLM now preserves these fields for buffered and streamed Images. Billing checks the split against the aggregate counts, uses separate text and image rates, and avoids a second per-image charge. An image-only model can use aggregate output when optional output details are absent.

Missing or inconsistent counts, partial rate coverage, mixed aggregate and modality rates, and reported cache usage without a modality allocation return unknown cost. When no cache use is reported, input uses the standard uncached rates. Cache prices remain in llmdb; no undocumented cache allocation is inferred.

The 82 focused billing, normalization, image decoder, and stream tests passed. The integration script loaded all four Image 2.5 records from the new llmdb snapshot and checked request routing and modality costs.

Source: [official Images response schema](https://github.com/openai/openai-python/blob/main/src/openai/types/images_response.py).

## Published catalog dependency

The user approved llmdb shipment on September 29, 2026. [PR #341](https://github.com/agentjido/llmdb/pull/341) passed GitHub CI and merged. The release workflow published [llm_db 2026.9.8](https://hex.pm/packages/llm_db/2026.9.8). ReqLLM now requires that version or later in the same minor series, and its lock file selects 2026.9.8. Other dependency versions are retained.

The integration script passed with the snapshot in the downloaded Hex package. The full suite passed 4,808 tests, with 11 skipped and 213 excluded. Quality checks passed. Catalog evidence was regenerated, and the missing-runtime test now uses an absent provider because OrcaRouter has runtime metadata. ReqLLM remains pending user review and has not been merged or published.
