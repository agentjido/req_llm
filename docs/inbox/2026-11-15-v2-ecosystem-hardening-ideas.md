---
title: ReqLLM V2 ecosystem hardening ideas
status: new
last-reviewed: 2026-11-15
---

# ReqLLM V2 ecosystem hardening ideas

## Purpose

This note records additive ideas from packages that use ReqLLM. These ideas can
make ReqLLM easier to test, inspect, and integrate without moving agent or
application responsibilities into ReqLLM.

This note is source material. It does not change the accepted V2 scope or
roadmap. Each idea needs direct code evidence, a small design, and separate
approval before it moves into a plan.

## Boundary

Deprecated third-party provider packages are out of scope. Do not add a
provider-extension kit, provider manifest, new provider DSL, or new support
contract for those packages.

ReqLLM continues to own one model interaction. Applications and host packages
continue to own agent loops, tool policy, persistence, routing policy, budgets,
memory, RAG, checkpoints, and approvals.

Do not add a second host wrapper or parallel versions of the current telemetry,
usage, cost, citation, structured-output, or stream APIs.

## Jido V3 consumer evidence

A review of Jido V3 on `release/v3` found these repeated integration tasks:

- Jido duplicates ReqLLM error classification, retryability, transport
  detection, and safe-message logic.
- Jido manually adds usage from independent model calls.
- Jido maps provider-specific prompt-cache options.
- Jido converts raw stream chunks into portable events and still needs the
  final materialized response.
- Jido must identify ReqLLM's synthetic `structured_output` tool so that it is
  not treated as an actionable tool call.
- Jido uses telemetry correlation to recover request IDs on failures because
  error results do not carry the same metadata as successful responses.
- Jido builds portable and redacted snapshots of ReqLLM values.
- `Jido.AI.InferenceClient` mirrors most ReqLLM operations. This makes test
  clients hard to maintain.

These findings show integration cost. They do not prove that each proposed API
belongs in ReqLLM.

## Ordered ReqLLM candidates

### 1. Stable error information

Add `ReqLLM.Error.info/1` as an additive projection. Keep every current error
struct and return shape. The projection can return stable policy facts:

```elixir
%{
  category: :rate_limited,
  retryable?: true,
  safe_message: "The provider rate limit was reached.",
  provider_status: 429,
  provider_code: "rate_limit_exceeded",
  call_metadata: %{request_id: "..."}
}
```

Candidate categories are `:timeout`, `:rate_limited`, `:unauthorized`,
`:invalid_request`, `:invalid_output`, `:unavailable`, `:transport`,
`:cancelled`, `:provider`, and `:unknown`.

The projection supplies facts only. ReqLLM must not make the host's retry,
fallback, or failure-policy decision. Call metadata must follow current
redaction rules.

### 2. Usage addition for independent calls

Add `ReqLLM.Usage.sum/2` and `ReqLLM.Usage.sum_all/1` for usage from independent
model calls.

Keep the existing max-style merge semantics separate. Merge and sum answer
different questions:

- merge combines partial observations of the same logical call; and
- sum adds usage from separate calls.

Tests must cover missing fields, mixed providers, pricing status, and unknown
costs. The helper must not claim a numeric cost when the source usage does not
support one.

### 3. Synthetic structured-output provenance

Mark synthetic structured-output calls with stable provenance. Exclude them
from actionable tool calls and normal tool classification while keeping their
raw details available for diagnostics.

The marker must survive buffered responses, streams, materialization, and
portable value encoding. It must not hide a real provider tool call that has a
similar name.

### 4. Stream event callback with final materialization

Add one canonical `on_event` callback to stream materialization. The callback
receives portable events while the same operation continues to build and
return the final materialized response.

The callback must not create a second independent stream consumer. Its error,
cancellation, ordering, resource cleanup, and back-pressure behavior need an
explicit contract.

### 5. Detailed result and error envelope

Add an optional detailed result envelope that carries call metadata on success
and failure. Existing tuple APIs and public error values remain unchanged.

The envelope can include request ID, provider identity, selected model,
operation, timing, retry information, and redacted transport facts. It must not
duplicate telemetry with a conflicting schema.

### 6. Common prompt-cache option

Add a common prompt-cache option that maps to provider-specific controls. Keep
`provider_options` as the escape hatch for features that the common option
cannot express.

The common option must state its support status during planning. It must not
silently add a foreign provider option or claim that two provider cache models
have the same semantics.

### 7. Stable capability planning and consumer test kit

Grow `ReqLLM.plan/3` in small additive steps. Candidate fields are:

- capability status and supporting evidence;
- a reason when an operation or option is unsupported;
- selected surface, route, transport, and result policy;
- translated option names and warnings; and
- facts that a host can use to decide if retry or replay is safe.

The diagnostic must stay redacted. It can explain a plan, but it must not
select routing, fallback, authorization, or budget policy.

Publish a small test-only API for consumers. It can provide:

- canonical response factories;
- deterministic stream events;
- tool-call and structured-output cases;
- timeout, rate-limit, cancellation, and provider-error cases;
- process-local stubs that are safe for asynchronous tests;
- buffered and materialized-stream compatibility assertions; and
- versioned conformance cases for the current host boundary.

ReqLLM already has fixture support under `test/support`, but the Hex package
does not include it. A public test kit must expose canonical ReqLLM values, not
recorded provider payloads. It must not add a mocking-framework dependency.

## Supporting candidates

### Portable ReqLLM value codec

Investigate a versioned codec for ReqLLM-owned values. Start with messages and
content parts. Add context support only after the smaller values are stable.

The codec must exclude callbacks, credentials, runtime tool functions, and
application state. A host continues to own lifecycle snapshots, transcript
format, workflow versions, storage, and resume policy.

Stored values can live longer than a package release. Test the codec with one
host before it becomes a stable contract.

### Rich-content round-trip contract

Add conformance cases that protect content through buffered calls, streams,
materialization, tool continuation, and optional value encoding. The cases
should verify that:

- reasoning parts keep their identity and order;
- signed thinking data remains attached to the correct part;
- tool calls keep their IDs and provider data;
- an empty-text refusal remains visible;
- citations and annotations survive materialization; and
- unknown provider data remains available through the current extension field.

Improve the current message and content structures. Do not create a second
message model.

## Jido-side simplification

ReqLLM changes do not remove all host work. Jido can simplify its side of the
boundary in these ways:

- Extract a reusable `Jido.AI.ModelCall` service from the large `CallModel`
  Action. Preserve budgets, context preparation, telemetry, session
  correlation, and streaming.
- Split or reduce the large `Jido.AI.InferenceClient` mirror into smaller
  capabilities or optional callbacks.
- Keep Jido lifecycle snapshots above a lower-level ReqLLM value codec.

These are Jido changes. They are not ReqLLM roadmap commitments.

## Tune alignment

Keep these ownership boundaries:

- Tune owns typed programs, predictors, evaluation, optimizers, and artifacts.
- ReqLLM owns model transport.
- Applications and Jido own tools, loops, authorization, budgets, and side
  effects.

Candidate Tune work:

- Add a generic executor boundary to Tune. The default executor calls ReqLLM.
  A host executor can route prepared calls through Jido without a Tune-to-Jido
  dependency.
- Support standalone Tune through ReqLLM.
- Evaluate through a real Jido Agent or Flow with the existing run closure.
- Run approved Tune predictors inside Jido through the guarded model-call
  boundary.
- Deploy approved Tune artifacts into Jido configuration. Do not optimize in
  each agent turn.
- If online tuning is required, use a separate Jido Flow with explicit limits.

Suggested next contract test: one offline test sends a Tune-prepared request
through the real Jido model-call boundary and returns the result to
`Tune.finish/2`.

## Compatibility guardrail

Create an offline downstream compatibility matrix before these ideas change a
public contract. Use representative host, typed-output, observability, RAG,
and evaluation cases. Prefer contract fixtures inside ReqLLM. Use external
package builds only as additional evidence because their main branches and
dependencies can change independently.

The matrix must protect documented shapes and meanings. It must not make
ReqLLM responsible for another package's agent or application behavior.

## Candidate trial order

1. Record downstream compatibility cases that current APIs support.
2. Add the stable error-information projection.
3. Add usage sum helpers with separate merge semantics.
4. Mark synthetic structured-output calls with provenance.
5. Add `on_event` to stream materialization with final response return.
6. Add the optional detailed result and error envelope.
7. Add the common prompt-cache option.
8. Stabilize capability planning and publish the consumer test kit.
9. Test a message and content-part codec with one host.
10. Add the offline Tune-to-Jido model-call contract test.

This is candidate order, not an active roadmap.

## Open questions

- Which error categories and call metadata are stable across all operations?
- How must usage addition handle unknown cost and mixed pricing status?
- What provenance distinguishes synthetic output calls from real tools?
- What happens when an `on_event` callback fails or becomes slow?
- Can one detailed envelope serve all operations without replacing current
  result types?
- Which prompt-cache concepts are common across providers?
- Which plan fields can become stable without exposing internal architecture?
- Should the consumer test kit stay in `req_llm`, or use a test-only package?
- Does a value codec remove enough host code to justify a storage contract?
- Which rich-content fields are canonical, and which remain provider data?

## Evidence

- Jido V3 `release/v3` consumer review, 2026-11-15.
- [Hex packages that depend on ReqLLM](https://hex.pm/packages/req_llm/dependents)
- [Ash AI migration to ReqLLM](https://github.com/ash-project/ash_ai/blob/main/documentation/topics/langchain-to-reqllm-migration.md)
- [AgentObs ReqLLM integration](https://github.com/lostbean/agent_obs#reqllm-integration-optional)
- [Arcana loop integration](https://github.com/georgeguimaraes/arcana/blob/main/lib/arcana/loop.ex)
- [LangChain release history](https://github.com/brainlid/langchain/releases)
- [Lemieux host and transcript boundary](https://github.com/houllette/lemieux)
- [`ReqLLM.Response.classify/1`](../../lib/req_llm/response.ex)
- [`ReqLLM.StreamResponse.events/1`](../../lib/req_llm/stream_response.ex)
- [`ReqLLM.plan/3`](../../lib/req_llm.ex)
- [Current Hex package file list](../../mix.exs)
