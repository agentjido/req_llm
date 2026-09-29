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
- [ ] Verify behavior with the updated llmdb catalog.
- [ ] Check Sol and Luna sampling behavior at reasoning effort none.
- [ ] Add multi-agent options and beta headers to HTTP, SSE, and WebSocket requests.
- [ ] Preserve agent identity in output, tool calls, history, and streaming events.
- [ ] Verify root final-answer assembly and aggregate usage.
- [ ] Add OpenAI Decisions support with a public operation, validated inputs, response types, tests, and documentation.
- [ ] Review September image quality, cache diagnostics, and voice support.
- [ ] Run required quality checks and prepare reviewable commits or a draft pull request.

## Decisions API: required contract

OpenAI confirms a Luna-based API with text or image context and finite predefined answers. It is in limited preview. Public searches have not found its technical contract.

The implementation requires official endpoint and authentication details, model identifiers, input and output schemas, error behavior, limits, access requirements, and pricing. Streaming and batching must be checked rather than assumed. Keep the existing OpenRouter decisions contract separate. Do not present ordinary structured generation as OpenAI Decisions support.

This missing contract does not prevent the independent model and Responses work. Decisions remains required before the full rollout is complete.

## Separate proposed integrations

Agents API computer use requires durable session handling, required-action events, browser access approvals, and authentication events. Propose a separate client module and tests after this rollout.

Bedrock Managed Agents requires an AWS-specific session client and authentication. It is not a model-name change in the existing Bedrock generation adapter.
