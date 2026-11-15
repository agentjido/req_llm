---
title: Consolidate ReqLLM architecture behind a stable public API
status: accepted
last-reviewed: 2026-11-15
---

# Consolidate ReqLLM architecture behind a stable public API

## Purpose

Define V2 as an architecture consolidation release. V2 can make substantial
internal changes when they improve package consistency and preserve public
behavior.

## Decision

ReqLLM V2 will use one consistent internal path for planning, provider
resolution, execution, and result normalization. The public API and observable
behavior will remain compatible with V1.

V2 is not a port of `reqllm_next`. It can adapt useful concepts from that
experiment to the current ReqLLM code and contracts.

The current repository is the authority for supported behavior. The closed V2
issue and `reqllm_next` are historical design sources only.

## Compatibility shell

The internal architecture can change substantially. These public contracts
must remain stable:

- documented functions, arities, inputs, options, defaults, and return tuples;
- supported model input forms and Router behavior;
- public structs, fields, defaults, equality, inspection, and JSON shapes;
- streaming element order, terminal behavior, cancellation, and projections;
- documented provider callbacks, helpers, registration, and option precedence;
- configuration, telemetry names, metadata, measurements, and redaction; and
- supported operations, providers, wrapper platforms, and host integrations.

Deprecated APIs remain functional. A separate accepted decision is required
before any public contract can leave this compatibility shell.

## Product boundary

ReqLLM owns one model interaction. It resolves a model, validates one request,
performs one request or stream, and returns normalized results.

Jido or another host owns loops, tool execution, approvals, memory, workflow
state, delegation, and durable execution.

## Consolidated architecture

```text
Public operation
  -> ModelResolver or Router
  -> operation descriptor
  -> RequestPlan
  -> Provider.Adapter
  -> internal ResolvedExecution
  -> Runtime
  -> operation result policy
  -> existing public result type
```

This is one execution path. V2 does not add a second runtime, provider bridge,
operation catalog, or independent stream source.

### Resolution and planning

An internal model resolver owns all accepted model forms, warnings, fallbacks,
and errors. Router resolution remains an explicit pre-plan step because it
needs messages and routing context.

`ReqLLM.ModelOperation` becomes the source for the mapping from an execution
operation to its option schema, evidence category, runtime action, and result
policy.

`RequestPlan` becomes the complete internal request plan for all operations.
Migration constructors can remain until each operation has equal contract and
fixture evidence.

### Provider execution

`Provider.Adapter` remains the compatibility boundary. It resolves an internal
`ResolvedExecution` value with hosting-provider identity, wire-protocol
identity, authentication, route, protocol, wire adapter, transport, and
response builder.

`ReqLLM.Provider` and `Provider.Defaults` remain supported public extension
surfaces. Their internals can move to smaller modules, but the existing macro,
callbacks, helpers, registration, option precedence, and routing behavior must
remain available through delegates.

### Results and streams

One internal reduction path normalizes buffered and streamed generation output.
It can use normalized internal output items or events when this removes
duplicate logic.

The internal model must project without loss to the existing `Response`,
`StreamResponse`, and `StreamChunk` contracts. Canonical events remain a named
public projection. They do not replace the raw stream.

Other operations keep explicit result policies. Embedding vectors, speech and
transcription results, rerank results, OCR results, video tasks and results,
and evaluation results do not have to pass through the generation reducer.
Their current public values and errors remain unchanged.

### Context

Internal callers can use Context accessors. V2 keeps `Context.messages` as a
chronological list because its value shape is public. A storage change is
outside this scope.

## Consolidation rules

1. Add a compatibility test before an internal contract moves.
2. Expand the current boundary before migrating callers.
3. Migrate one operation or protocol family at a time.
4. Keep the old internal path until equal behavior is proven.
5. Remove the old path only after all callers have moved.
6. Do not mix an architecture change with a public behavior change.
7. Use recorded fixtures before separately authorized live provider checks.
8. Preserve a clear rollback point for each migration unit.

## Functionality that V2 must preserve

- All current operation families, including text, object, embedding, image,
  speech, transcription, rerank, OCR, video, compaction, and evaluation.
- Router input and behavior.
- String, tuple, plain-map, and `%LLMDB.Model{}` model inputs supported by V1.
- Explicit models that do not require catalog membership when routing metadata
  is sufficient.
- Current providers, wrapper platforms, and custom-provider capabilities.
- Flat and namespaced provider option forms.
- Current structured-output validation defaults and explicit policies.
- Current streaming functions, raw chunks, named projections, and terminal
  behavior.
- The one-call host boundary used by Jido and other applications.

## Ideas adapted from `reqllm_next`

- A deterministic planning path.
- Clear provider, protocol, wire, transport, and response ownership.
- An internal resolved execution stack.
- Rich internal generation output before public convenience projections.
- Provider-owned differences and reuse of protocol families.
- Scenario tests, recorded fixture replay, and focused live verification.
- A smaller public module with model resolution behind an internal boundary.

## Ideas not in V2 scope

- A full rewrite or module-tree port.
- A public API, input, output, option, callback, struct, or default removal.
- Canonical events as the default raw stream.
- Strict structured-output validation as a new default.
- Rejection of flat provider options.
- Replacement of the public provider behavior.
- Opaque Context storage.
- A Spark DSL or compile-time extension manifest.
- A new specification or work-tracking system.
- An Elixir version increase only to match the experiment.
- A broad paid live-provider matrix.

## Open decisions

1. The exact V2 release date and version policy remain with the project owner.
2. The final internal generation output representation can be selected after
   compatibility tests state the required information and ordering.

These decisions do not block the first step in the
[V2 roadmap](../plans/v2-roadmap.md).

## Sources

- [V2 scope](../plans/v2-scope.md)
- [ReqLLM V1 compatibility policy](../../COMPATIBILITY.md)
- [V2 migration audit](../../guides/v2-migration-audit.md)
- [Provider extension decision](../../guides/provider-extension-decision.md)
- [Closed historical V2 issue 830](https://github.com/agentjido/req_llm/issues/830)
- [Experimental reqllm_next repository](https://github.com/mikehostetler/reqllm_next)
- [V2 source map](../reference/v2-source-map.md)
