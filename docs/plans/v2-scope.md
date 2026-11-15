---
title: ReqLLM V2 architecture consolidation scope
status: current
last-reviewed: 2026-11-15
---

# ReqLLM V2 architecture consolidation scope

## Work brief

**Outcome:** ReqLLM V2 has one consistent internal architecture for all model
operations. Existing applications and provider extensions continue to work
without a public API migration.

**Why:** ReqLLM has the required functionality, but related decisions remain
spread across the public module, operation modules, provider defaults,
response builders, and streaming paths. Consolidation reduces maintenance cost
and makes package behavior easier to reason about.

**Consumer:** ReqLLM maintainers, provider authors, application authors, and
the release owner.

**Includes:**

- A complete compatibility contract for APIs, inputs, defaults, Router,
  provider extensions, values, streams, telemetry, and host integration.
- One internal source for operation metadata.
- One internal model-resolution boundary.
- Router-aware planning and one `RequestPlan` path for all operations.
- One internal resolved provider execution value through `Provider.Adapter`.
- Smaller provider-default modules behind the existing public wrapper.
- Early selection of response normalization behavior in the request plan.
- One internal result-reduction path for buffered and streamed generation
  output.
- Explicit result policies for operations that return embeddings, media,
  rerank results, OCR results, video tasks, or evaluation results.
- Operation-by-operation and protocol-family migration with fixture evidence.
- Removal of superseded internal branches after all callers move.
- Offline fixture, test, quality, documentation, and package verification.

**Excludes:**

- Public function, input, output, option, callback, struct, or default changes.
- Removal of deprecated bang streaming functions.
- Rejection of flat provider options.
- Strict structured-output validation as a new default.
- Canonical events as the default raw stream.
- Replacement of the public provider extension contract.
- Context storage changes.
- Reduced provider, operation, model-input, or wrapper-platform support.
- A Spark manifest, new provider DSL, or second runtime.
- LLMDB or LLMCatalog changes.
- New runtime dependencies unless a separate decision approves them.
- Live or paid provider checks without separate authority.

**Done when:**

- Every operation uses the consolidated planning and execution path.
- Provider, protocol, wire, transport, and response ownership is explicit.
- Buffered and streamed generation results use one internal reduction
  contract.
- Other operations keep their current public result types and errors.
- Superseded internal branches and duplicate decision maps are removed.
- All documented V1 behavior and defaults remain available in V2.
- Public, provider-extension, value, streaming, Router, telemetry, and host
  contract suites pass.
- Recorded provider fixtures pass without live provider calls.
- The full test suite, `mix quality`, documentation build, and package dry-run
  pass for the release candidate.
- The migration audit reports no new required application migration caused by
  V2.

**Inputs and dependencies:**

- Current ReqLLM code and tests.
- [`COMPATIBILITY.md`](../../COMPATIBILITY.md).
- The accepted [V2 direction](../decisions/2026-11-15-v2-direction.md).
- The historical migration ledger and issue 830, which must be reconciled with
  this compatibility scope before release work starts.
- The `reqllm_next` experiment as non-authoritative design evidence.

**Authority:** This scope permits planning and separately authorized local
implementation. It does not authorize a release, live provider call, or public
breaking change.

**Open decisions:** The project owner retains the release date and final
version policy. The internal output representation remains a technical design
decision inside the compatibility shell.

**Next owner:** After V2-00 merges, a software planner can prepare V2-01, the
compatibility matrix and migration-ledger reconciliation step.

## Main risks and controls

| Risk | Control |
| --- | --- |
| Router needs messages and routing context that a normal model plan does not have. | Keep Router resolution explicit and add Router-to-plan contract tests before planner migration. |
| Wrapper platforms separate hosting identity from wire identity. | Store both identities in the internal execution value and test Azure, Vertex, Bedrock, and OpenRouter. |
| External providers can use callbacks and `Provider.Defaults` helpers directly. | Preserve the full public wrapper with delegates and run provider-extension contracts at every provider step. |
| Stream consolidation can lose ordering, terminal events, reasoning, tools, media, usage, or errors. | Define lossless compatibility cases first and migrate one protocol family at a time with recorded fixtures. |
| A large migration can leave two competing runtimes. | Expand existing boundaries, migrate callers, then remove the old branch. Do not create a second top-level runtime. |
| Broad refactoring can hide a behavior change. | Keep architecture and behavior changes in separate pull requests. Require exact request, response, error, telemetry, and fixture checks. |
| Current tests can miss third-party use. | Preserve documented shapes, survey known provider authors before internal callback removal, and keep public delegates. |

## Scope status

`scope-ready`
