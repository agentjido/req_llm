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

- [x] Recognize GPT-6.1 Sol as a reasoning model.
- [x] Route explicit GPT-6 model specifications to Responses when wire metadata is absent.
- [x] Validate GPT-6.1 Sol reasoning efforts and unsupported parameters.
- [x] Document Fast and Ultrafast service-tier values in the option schema.
- [ ] Complete transport checks. The first provider checks passed: 30 tests.
- [x] Verify GPT-6.1 Sol routing and cache pricing with the updated llmdb snapshot.
- [x] Check Sol and Luna sampling behavior at reasoning effort none. Sampling fields are retained at none and removed at higher efforts.
- [x] Add multi-agent options and beta headers to HTTP, SSE, and WebSocket requests. Focused request tests pass. Output and history support remain incomplete.
- [ ] Preserve agent identity in output, tool calls, history, and streaming events.
- [ ] Verify root final-answer assembly and aggregate usage.
- [x] Defer OpenAI Decisions support to [issue #1062](https://github.com/agentjido/req_llm/issues/1062). The user removed it as a release requirement.
- [ ] Review September image quality, cache diagnostics, and voice support.
- [x] Run required quality checks and prepare separate local commits for review. `mix quality` passed after the final code changes.

## Decisions API: deferred contract

OpenAI confirms a Luna-based API with text or image context and finite predefined answers. It is in limited preview. Public searches have not found its technical contract.

The implementation requires official endpoint and authentication details, model identifiers, input and output schemas, error behavior, limits, access requirements, and pricing. Streaming and batching must be checked rather than assumed. Keep the existing OpenRouter decisions contract separate. Do not present ordinary structured generation as OpenAI Decisions support.

This missing contract does not prevent the independent model and Responses work. The user approved shipment without Decisions support on September 29, 2026. Issue #1062 tracks the remaining work.

## Separate proposed integrations

Agents API computer use requires durable session handling, required-action events, browser access approvals, and authentication events. Propose a separate client module and tests after this rollout.

Bedrock Managed Agents requires an AWS-specific session client and authentication. It is not a model-name change in the existing Bedrock generation adapter.

## Validation record

The model request checks passed 149 tests, including WebSocket checks. The multi-agent request checks and adjacent model checks passed 12 tests. These checks do not prove complete multi-agent support. Output, history, and usage work remains required.

The first multi-agent output checks passed 22 tests. Buffered output selects root text. Function calls retain agent attribution. Raw output items are kept for stateless replay. Stream chunks keep attribution and final response assembly excludes child text. Additional stream completion, compaction, and cross-repository checks remain required.

Sampling and adjacent provider checks passed 120 tests. Run the cross-repository check with `MIX_ENV=test mix run scripts/check_devday_catalog.exs /absolute/path/to/llmdb/priv/llm_db/snapshot.json`. It loads the snapshot in a separate process and prepares a request without sending it.

## September review status

ReqLLM already accepts Image 2.5 quality values `xhigh` and `max`. The local llmdb image records required correction. Prompt cache options and content breakpoints are already encoded in the request. Responses keeps additional response fields in provider metadata. The exact cache diagnostic response fields still need a direct source and focused checks.

GPT Live 1 requires a session protocol and time-based usage accounting. This is separate client work. Do not route it through ordinary text generation based only on its model name. The catalog record needs further review.
