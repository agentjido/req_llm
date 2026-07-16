# ReqLLM 1.x Compatibility Policy

ReqLLM 1.x evolves without requiring applications or third-party providers to
rewrite working integrations. Internal architecture may change substantially,
but stable observable behavior follows semantic versioning.

This policy applies to the 1.x release line. The
[V1 roadmap](ROADMAP_V1.md) describes planned compatible improvements, and the
[V1 execution goal](V1_EXECUTION_GOAL.md) defines the evidence required before
each roadmap pull request can merge.

## Contract classifications

Every supported surface is classified as stable, experimental, deprecated, or
internal.

### Stable

A surface is stable when it is documented without an experimental or deprecated
label. Stable contracts may gain additive behavior in a minor release, but an
incompatible removal, rename, default change, or semantic replacement waits for
a major release.

Stable does not mean frozen. Internal implementation and private data may change
when existing observable behavior remains compatible. A narrowly scoped bug fix
may correct behavior that contradicts the documented contract or types, provided
the change has regression evidence and does not introduce unrelated differences.

### Experimental

A surface is experimental only when its module, function, option, event, or
guide explicitly says so. Experimental contracts may change or be removed in a
minor release, but changes must still be intentional, documented, and tested.
New public behavior is not implicitly experimental.

Applications should isolate experimental use behind their own adapter. ReqLLM
will prefer an additive migration path and warning when practical, especially
when an experimental surface has meaningful adoption.

### Deprecated

A deprecated contract remains functional while users migrate. A deprecation
must provide:

- an actionable warning where runtime detection is practical;
- the supported replacement and a migration example;
- the release that introduced the deprecation;
- the earliest release in which removal may occur; and
- at least two minor releases of overlap before removal is considered.

Stable runtime APIs are not removed during V1 merely because the overlap window
has elapsed. Their removal belongs to a major release. The window creates a
usable V1 bridge before that release.

### Internal

A surface is internal only when it is hidden from public documentation or
explicitly documented as internal. File paths, private functions, intermediate
maps, and module organization are not contracts by themselves.

Visibility alone does not make an extension point internal. Documented provider
callbacks, configuration, telemetry, and value shapes remain protected even
when most applications use them indirectly.

## Compatibility-protected contracts

The following categories are stable unless their documentation explicitly
classifies a particular surface otherwise.

### Public functions and inputs

- Documented facade and operation functions, their names, arities, bang
  variants, defaults, and return tuples.
- Accepted model forms, including `"provider:model"` strings, supported tuple
  forms, full plain-map model specs, and `%LLMDB.Model{}` values.
- Documented option names, types, precedence, and default behavior, including
  provider-specific escape hatches.
- The ability to use a full model specification without requiring LLMDB catalog
  membership when enough routing metadata is present.

Adding an opt-in function or option is compatible. Silently changing an existing
default, precedence rule, or accepted input is not.

### Results, values, and errors

- Success and error tuple shapes, normalized content, usage, warnings, finish
  reasons, provider metadata, and ordering.
- Public struct modules, keys, defaults, equality behavior, `Map.from_struct/1`
  output, `Inspect` representation, and Jason encoding.
- Public error terms and fields plus the exception module and message raised by
  bang functions.

Richer information must use a computed projection, a new value, or an explicit
opt-in return mode when adding fields would change an existing value's observable
shape.

### Streaming

- The `StreamResponse.stream` and `StreamChunk` contract, element order and
  meaning, and single-consumer behavior.
- Terminal success and failure delivery, cancellation, timeout semantics,
  metadata availability, and transport resource cleanup.
- Semantic parity between a buffered stream and the equivalent non-streaming
  operation where both surfaces support the same provider capability.

A richer event view may project from the existing stream. V1 does not replace
the legacy stream with a second independently consumable source.

### Provider extensions

- The documented `ReqLLM.Provider` callbacks and default implementations.
- Provider registration, `:custom_providers`, inline model specs, and documented
  request customization.
- Callback inputs, return forms, option precedence, and routing behavior relied
  upon by third-party provider modules.

ReqLLM may introduce narrower internal seams, but the current provider behavior
remains available through V1. A first-party refactor must include conformance
evidence that an external provider would continue to work.

### Configuration and telemetry

- Documented application configuration, environment variables, per-request
  options, precedence, defaults, and credential-source behavior.
- Existing documented telemetry event names, metadata and measurement keys,
  value types, meanings, units, and redaction behavior.

New telemetry is additive. Existing events are not silently renamed or corrected
in place when that would reinterpret a consumer's data. Provider-specific or
detail events may use an experimental classification only when that status is
explicit in their documentation.

### Compatibility evidence

- Public scenario identifiers, fixture naming and lookup rules, replay/live
  behavior, semantic test tags, support-state meanings, and generated evidence
  schemas.
- Existing fixture request contracts outside the exact behavior being fixed.

Recorded provider responses may be refreshed when a provider changes, but the
pull request must distinguish provider drift from a library regression. Internal
refactoring alone must not churn fixture payloads or support claims.

## Elixir and OTP support

The Elixir requirement in `mix.exs` and the versions exercised by GitHub CI are
the source of truth for the supported toolchain. Toolchain support is managed
independently from the ReqLLM API major version because language, OTP, security,
dependency, and CI constraints have their own lifecycle.

Raising the minimum Elixir or OTP version does not by itself require ReqLLM 2.0,
but it is never treated as incidental maintenance. Except for an urgent security
or ecosystem incompatibility, ReqLLM will:

1. announce the intended minimum-version change at least one minor release in
   advance;
2. explain the EOL, security, dependency, or maintenance evidence behind it;
3. keep the old version in CI during the notice window;
4. include a concrete upgrade path in release notes; and
5. change package metadata, CI coverage, and documentation together.

Supporting an additional Elixir or OTP release is compatible when the existing
matrix remains green.

## ReqLLM and Jido ownership

ReqLLM owns one model interaction. It resolves and validates the selected model,
translates options, performs one request or stream, and normalizes provider data
into responses, tool calls, usage, warnings, and errors. It may provide pure
helpers that let a host append matched tool calls and results to a context.

Jido or another application host owns orchestration across model interactions:

- deciding whether and where a tool runs;
- approvals and tool-execution policy;
- appending application results and deciding whether to call a model again;
- loop termination, step limits, model selection, and cross-call retry policy;
- memory, checkpoints, resumption, delegation, and durable execution; and
- sandbox creation, permissions, lifecycle, and cleanup.

Concrete boundaries include:

| Situation | ReqLLM owns | Jido or the host owns |
| --- | --- | --- |
| A response requests a tool | Decode and return a normalized tool call. | Approve, execute, reject, or defer it. |
| A tool produced a result | Represent model-facing tool result content and offer pure context helpers. | Preserve application data and decide whether to make another model call. |
| A provider returns a transient transport failure | Apply the documented retry behavior within the current operation. | Decide whether the workflow retries the completed model step or chooses another model. |
| A caller cancels a stream | Stop the current operation and release transport resources. | Pause, resume, checkpoint, or terminate the larger workflow. |
| A provider offers a native or server-side tool | Encode and decode the provider-scoped capability for one operation. | Decide whether the capability is allowed and how its effects fit the workflow. |

ReqLLM core does not add an agent loop, approval engine, memory store, workflow
checkpoint, delegation runtime, or Jido dependency. Optional integration code
may adapt stable ReqLLM values for Jido without moving those responsibilities
across the boundary.

## Evaluating a V1 change

Before merging a V1 change, identify every affected contract above and prove
that behavior outside the accepted scope remains compatible. Exact request,
serialization, error, exception, telemetry, and fixture assertions are required
when those contracts are touched.

If the valuable implementation cannot satisfy the V1 compatibility gate, narrow
it to an additive bridge or move it to the V2 roadmap. Compatibility uncertainty
is a reason to pause, not permission to guess.
