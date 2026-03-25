# Pricing Policy

ReqLLM currently targets **"some assistance, no guarantees"** for pricing and cost tracking.

That means the library helps you collect normalized usage data and compute USD cost estimates, but it does **not** promise that `response.usage.total_cost` will always match a provider invoice exactly.

## Public Contract

ReqLLM will:

- normalize usage data such as input, output, reasoning, cached, tool, and image counts when the provider exposes enough information
- calculate best-effort cost data from model metadata, pricing components, and provider response metadata
- expose that data consistently through `response.usage`, telemetry events, and streaming metadata
- let you override or patch pricing metadata locally when your deployment differs from the shared registry

ReqLLM does not guarantee:

- exact invoice parity with provider billing
- enterprise contract pricing, regional overrides, taxes, credits, or other account-specific adjustments
- immediate coverage for every newly launched model, tool, or billing mode
- unmodeled charges such as realtime audio/text billing or video generation billing

## Why The Policy Is Best-Effort

Provider billing is not uniform. Some providers return direct totals, some return token counts only, and some bill for extra units such as searches, cache reads, storage, or media generation. Pricing data may also come from multiple sources:

- provider response metadata
- shared registry metadata from `llm_db`
- local patches in `priv/models_local/`
- provider-specific logic inside ReqLLM

ReqLLM uses those sources to give you a consistent, useful estimate, but they are still an abstraction over provider billing systems that can change independently.

## What We Test

ReqLLM tests and fixtures verify that:

- supported models return normalized usage data
- modeled token, tool, and image costs are calculated consistently
- provider-specific pricing features we already support continue to work

Those tests are important, but they are not a guarantee of invoice-exact billing across every provider plan or deployment.

## Known Gaps

These limitations are known and should not be treated as supported billing guarantees:

- video generation pricing, such as OpenAI Sora-style billing
- realtime audio/text pricing
- deprecated pricing surfaces that ReqLLM intentionally does not model

## Recommended Production Posture

Use ReqLLM cost data as an application-friendly estimate and observability surface, then reconcile against provider billing when exact accounting matters.

If you need higher accuracy for your deployment:

- update `llm_db` regularly
- patch pricing metadata locally in `priv/models_local/`
- compare representative traffic against provider invoices
- open issues or PRs when you find a mismatch in already modeled billing paths

See also:

- [Usage & Billing](usage-and-billing.md)
- [Model Metadata](model-metadata.md)
- [Fixture Testing](fixture-testing.md)
