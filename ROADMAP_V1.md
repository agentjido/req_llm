# ReqLLM 1.x Roadmap

> Backward-compatible evolution — discussion draft, July 16, 2026

[Back to the roadmap index](ROADMAP.md) ·
[Compatibility policy](COMPATIBILITY.md) ·
[V1 execution goal](V1_EXECUTION_GOAL.md) ·
[V2 roadmap](ROADMAP_V2.md) ·
[Master tracking issue #829](https://github.com/agentjido/req_llm/issues/829)

ReqLLM 1.x should evolve in place. New contracts are additive, internal
architecture moves behind adapters, stricter behavior is opt-in, and removals or
default changes wait for V2. The goal is a safer model runtime with a familiar
facade, not a disguised rewrite.

## V1 compatibility rules

- Preserve generate_text/3, stream_text/3, generate_object/4,
  stream_object/4, existing return tuples, and current model input forms.
- Preserve Response, StreamResponse, StreamChunk, message, tool, usage, and
  error semantics, including public struct keys/defaults, `Map.from_struct/1`,
  `Inspect`, JSON output, public error terms, and bang exception behavior.
- Keep the current provider behavior available through an adapter for all of V1.
- Introduce opt-in strictness before changing a default.
- Give every deprecation an actionable warning, migration example, target
  release, and at least two minor releases before removal.
- Treat silent loss or contradiction of documented input as a bug fix, with a
  regression test and release note.
- Keep agent loops, approvals, memory, durable execution, and retries across
  model calls in Jido.

## Milestones

### Milestone 0 — Publish the compatibility promise

Document stable, experimental, and deprecated contracts; lock the public facade
and provider extension behavior with tests; expose evidence-based support tiers.

**Exit:** users can tell what is stable, what is experimental, and what ReqLLM
has actually verified.

### Milestone 1 — Scenario-driven compatibility

Harvest the reusable scenarios from origin/v2/reqllm-next-architecture into one
compiled declarative catalog. Make tests, fixtures, Mix tasks, support evidence,
and the generated coverage view share the same IDs and applicability rules.

Replay stays the normal CI path. A sparse scheduled live lane detects provider
drift without making routine CI credential-dependent.

**Exit:** major runtime refactors can be measured against the same public
scenarios before and after the change.

### Milestone 2 — Deterministic planning behind the facade

Normalize accepted model inputs correctly and introduce one small internal
request-plan value with a named provider surface, normalized options, transport,
and warnings. Route provider surfaces through it incrementally. Add namespaced
provider options and harden the canonical reasoning options already present on
`main` without removing legacy inputs.

**Exit:** a request can be explained before execution, and invalid
provider/feature/transport combinations fail before network I/O.

### Milestone 3 — Canonical results and streaming

Add canonical output projections and call metadata only where existing response
values lose meaning. Add a tagged event projection over the one consumable
legacy stream, consolidate the existing accumulator and response builders, and
make total-call, request, idle, and cancellation semantics explicit without
duplicating timeout controls.

**Exit:** buffering a stream and making the equivalent non-streaming call
produce semantically equivalent canonical results.

### Milestone 4 — Structured output contracts

Add text, object, array, choice, and JSON output descriptors to text generation.
Keep generate_object and stream_object as convenience wrappers. Add explicit
strict, warning, and permissive validation plus visible, bounded repair.

**Exit:** a structured success cannot violate its declared final contract
without an explicit permissive policy and warning.

### Milestone 5 — Tool and orchestration extensions

Harden the existing Tool, ToolCall, and ToolResult values, distinguish
application results from model-facing result content, provide pure serializable
continuation helpers, and document/test the public one-call host boundary.
ReqLLM does not add a parallel invocation facade and never starts a follow-up
model call.

Jido owns loop termination, step limits, approvals, model/tool selection,
cross-call retries, memory, checkpointing, resumption, delegation, durability,
and sandbox lifecycle.

**Exit:** Jido can drive and persist a provider-independent tool loop using
stable ReqLLM contracts while ReqLLM remains a one-call runtime.

### Milestone 6 — Provider extension ergonomics

Move first-party providers into cohesive vertical slices and extract narrower
wire, transport, and materialization seams only where current code demonstrates
duplication. Harden and document the local provider registration already on
`main`. Defer a general middleware framework, and consider a manifest only after
plain module/data declarations demonstrate concrete limits.

**Exit:** a compatible provider surface normally adds one focused slice and
scenario evidence rather than branches throughout shared code.

### Milestone 7 — Observability and developer experience

Stabilize a small redacted telemetry core and its timings, then add doctor,
sanitized plan/route diagnostics, and machine-readable deprecation/migration
tooling. Provider-specific telemetry remains experimental unless real consumer
evidence requires stability.

**Exit:** common failures identify the failed layer, selected surface,
remediation, and a safe correlation ID.

### Milestone 8 — Files, media, realtime, and provider-native depth

Add opt-in ownership and lifecycle to provider file references without changing
legacy content parts, then expose transcription and speech metadata through
opt-in detailed results. Harden OCR and realtime one family at a time while
preserving exact legacy results and errors. Image and reranking result
normalization already exists on `main`. Preserve operation entrypoints and
dedicated result types without forcing every modality through chat.

MCP and provider-trained tools stay provider-scoped or in optional packages.
Realtime shares canonical events but leaves session orchestration to the
application or Jido.

**Exit:** a new modality reuses core contracts while retaining an explicit
operation lifecycle.

## Issue strategy

Issue #829 is the only V1 master tracker. The audit considered all 42 proposed
issues, #831 through #872. It leaves 36 active implementation issues; three are
already satisfied by current `main`, two are consolidated into stronger issues,
and one speculative framework is deferred. Each active issue maps to one pull
request and one Conventional Commit squash title.

The implementation backlog follows these rules:

1. One issue closes through one pull request. The squash title is the changelog
   unit.
2. A pull request may include the contract, implementation, tests, fixtures, and
   directly affected documentation for one coherent outcome.
3. Group work only when it has one compatibility classification, rollback
   boundary, and validation story.
4. Keep separate issues for different provider surfaces, independent public API
   features, and different media operations.
5. Open backlog does not mean active execution. Work the dependency order and
   take only one ticket through implementation, review, hardening, and merge at
   a time.
6. New scope beyond the 36 active tickets requires an explicit roadmap decision.
7. If a ticket grows beyond one reviewable pull request, split or re-scope it
   before implementation begins and record the decision in #829.

Priority means:

- **P0:** compatibility safety, evidence, and known correctness.
- **P1:** planning, result, and streaming foundations.
- **P2:** structured output and Jido-facing tool contracts.
- **P3:** provider extensibility, observability, and developer experience.
- **P4:** files, media, realtime, and provider-native depth.

## Concrete ticket backlog

### P0 — Compatibility safety and evidence

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 1 | [#831](https://github.com/agentjido/req_llm/issues/831) | Define compatibility and ReqLLM/Jido runtime boundaries | <code>docs: define ReqLLM 1.x compatibility boundaries</code> | — |
| 2 | [#832](https://github.com/agentjido/req_llm/issues/832) | Inventory existing tests and fill public/provider-extension contract gaps | <code>test: lock ReqLLM public extension contracts</code> | #831 |
| 3 | [#833](https://github.com/agentjido/req_llm/issues/833) | Stop silently discarding tuple model options | <code>fix: handle tuple model specification options</code> | #832 |
| 4 | [#834](https://github.com/agentjido/req_llm/issues/834) | Introduce the compiled compatibility scenario catalog | <code>refactor: centralize compatibility scenario metadata</code> | #832 |
| 5 | [#835](https://github.com/agentjido/req_llm/issues/835) | Consolidate current scenarios and fixture guardrails | <code>test: consolidate compatibility scenarios</code> | #834 |
| 6 | [#836](https://github.com/agentjido/req_llm/issues/836) | Produce evidence-backed coverage and support tiers | <code>feat: add evidence-backed model support tiers</code> | #835 |
| 7 | [#837](https://github.com/agentjido/req_llm/issues/837) | Add sparse live provider drift verification | <code>ci: add sparse live provider drift verification</code> | #836 |

Issues #833 and #834 can proceed independently after #832. The #834 → #835 →
#836 → #837 chain is intentionally sequential so catalog, evidence, and CI
contracts are learned in order.

### P1 — Planning and inputs

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 8 | [#838](https://github.com/agentjido/req_llm/issues/838) | Introduce one small deterministic internal request-plan value | <code>refactor: add internal request planning</code> | #832, #833 |
| 9 | [#839](https://github.com/agentjido/req_llm/issues/839) | Route OpenAI Chat Completions and Responses selection through the plan | <code>refactor: plan OpenAI text requests</code> | #838 |
| 10 | [#841](https://github.com/agentjido/req_llm/issues/841) | Route Anthropic Messages through the plan | <code>refactor: plan Anthropic Messages requests</code> | #838 |
| 11 | [#842](https://github.com/agentjido/req_llm/issues/842) | Expose a small sanitized plan and route summary | <code>feat: add execution plan inspection</code> | #839, #841 |
| 12 | [#843](https://github.com/agentjido/req_llm/issues/843) | Harden existing canonical reasoning translation and warnings | <code>fix: harden canonical reasoning options</code> | #838 |
| 13 | [#844](https://github.com/agentjido/req_llm/issues/844) | Accept namespaced provider options beside the V1 legacy shape | <code>feat: add namespaced provider options</code> | #838 |

The request plan stays one coherent internal contract. OpenAI owns both of its
existing text API surfaces in one dispatcher, so they migrate together rather
than through two overlapping pull requests. Anthropic remains a separate parity
slice. Reasoning hardening and provider-option namespacing remain independently
revertible.

### P1 — Canonical results and streaming

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 14 | [#845](https://github.com/agentjido/req_llm/issues/845) | Add computed output and call-metadata projections without changing Response or legacy JSON | <code>feat: add model call projections</code> | #832 |
| 15 | [#846](https://github.com/agentjido/req_llm/issues/846) | Add one canonical event projection without a second consumable stream | <code>feat: add canonical stream event projections</code> | #845 |
| 16 | [#847](https://github.com/agentjido/req_llm/issues/847) | Consolidate OpenAI Chat Completions on the existing accumulator and response builder | <code>refactor: share OpenAI Chat Completions result materialization</code> | #839, #845, #846 |
| 17 | [#848](https://github.com/agentjido/req_llm/issues/848) | Adopt shared materialization for OpenAI Responses | <code>refactor: share OpenAI Responses materialization</code> | #839, #847 |
| 18 | [#849](https://github.com/agentjido/req_llm/issues/849) | Adopt shared materialization for Anthropic Messages | <code>refactor: share Anthropic Messages materialization</code> | #841, #847 |
| 19 | [#850](https://github.com/agentjido/req_llm/issues/850) | Unify total-call, existing request-timeout, idle, cancellation, and terminal semantics | <code>feat: add model call timeout budgets</code> | #846 |

Output items and call metadata form one result contract. The stream bridge is a
separate public capability. Materializer adoption stays isolated by provider
surface so each migration remains measurable and revertible.

### P2 — Structured outputs, tools, and Jido extensions

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 20 | [#851](https://github.com/agentjido/req_llm/issues/851) | Add text, object, array, choice, and JSON output descriptors plus output contracts on text generation | <code>feat: add structured output contracts</code> | #845 |
| 21 | [#852](https://github.com/agentjido/req_llm/issues/852) | Make existing extraction, repair, and final validation explicit without a general coercion framework | <code>feat: add visible structured output validation policies</code> | #851 |
| 22 | [#853](https://github.com/agentjido/req_llm/issues/853) | Harden the existing Tool, ToolCall, and ToolResult exchange contracts | <code>feat: harden canonical tool exchange contracts</code> | #845 |
| 23 | [#854](https://github.com/agentjido/req_llm/issues/854) | Add minimal pure helpers for appending matched tool calls and results to Context | <code>feat: add tool context continuation helpers</code> | #853 |
| 24 | [#855](https://github.com/agentjido/req_llm/issues/855) | Document and test the existing one-call host boundary without a parallel facade | <code>docs: define the one-call host integration contract</code> | #846, #853, #854 |

ReqLLM ends each operation after one model interaction. Issue #855 documents and
tests the existing public host boundary but does not add a parallel facade, loop
termination, approvals, memory, cross-call retries, checkpointing, durability,
or a Jido runtime dependency.

### P3 — Provider architecture and extensions

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 25 | [#856](https://github.com/agentjido/req_llm/issues/856) | Extract only measured OpenAI Chat Completions provider seams around current modules | <code>refactor: separate OpenAI Chat Completions provider seams</code> | #847 |
| 26 | [#859](https://github.com/agentjido/req_llm/issues/859) | Decide from implementation evidence whether a provider extension manifest is earned | <code>docs: decide the provider extension manifest</code> | #832, #856 |

Provider seams are proven on one reference surface before further migrations.
Current `Providers.register/1`, `:custom_providers`, and inline model specs already
cover local registration, so their remaining conformance belongs in #832 and
planning/evidence tickets. A general middleware framework is deferred. The
manifest decision is an evidence-backed architecture record, not a commitment
to a compile-time framework.

### P3 — Observability and developer experience

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 27 | [#860](https://github.com/agentjido/req_llm/issues/860) | Stabilize the small public telemetry core and classify all other events as experimental | <code>feat: stabilize ReqLLM runtime telemetry</code> | #838, #845, #846, #850 |
| 28 | [#861](https://github.com/agentjido/req_llm/issues/861) | Add environment and configuration diagnostics through mix req_llm.doctor | <code>feat: add ReqLLM environment diagnostics</code> | #842 |
| 29 | [#863](https://github.com/agentjido/req_llm/issues/863) | Add a deprecation ledger and only precise mechanical V2 migration checks | <code>feat: add the V2 migration audit</code> | #831, #844, #846, #852 |

These tickets build on the telemetry and OpenTelemetry support already present
in ReqLLM. A safe route and translated-option-key summary is part of #842;
encoded request previews are deferred because they duplicate provider encoding
and materially increase leak risk.

### P4 — Files, media, realtime, and provider-native depth

| Order | Issue | Outcome | Squash/PR title | Depends on |
| ---: | --- | --- | --- | --- |
| 30 | [#864](https://github.com/agentjido/req_llm/issues/864) | Add opt-in provider ownership without changing legacy ContentPart values or encoding | <code>feat: add owned provider file references</code> | #832 |
| 31 | [#865](https://github.com/agentjido/req_llm/issues/865) | Add provider-scoped OpenAI file uploads without making uploads a universal abstraction | <code>feat: add OpenAI file uploads</code> | #864 |
| 32 | [#867](https://github.com/agentjido/req_llm/issues/867) | Add opt-in transcription call metadata without expanding Transcription.Result | <code>feat: add transcription call metadata</code> | #832, #860 |
| 33 | [#868](https://github.com/agentjido/req_llm/issues/868) | Add opt-in speech call metadata without expanding Speech.Result | <code>feat: add speech call metadata</code> | #832, #860 |
| 34 | [#870](https://github.com/agentjido/req_llm/issues/870) | Harden OCR observability while preserving exact success, error, and bang behavior | <code>fix: harden OCR operation observability</code> | #832, #860 |
| 35 | [#871](https://github.com/agentjido/req_llm/issues/871) | Map only exact realtime event overlap while preserving provider-native events | <code>refactor: normalize OpenAI realtime events</code> | #846, #853, #860 |
| 36 | [#872](https://github.com/agentjido/req_llm/issues/872) | Define MCP, provider-native tool, and future operation boundaries | <code>docs: define provider-native integration boundaries</code> | #831, #853, #855, #864 |

Each existing operation remains explicit. These tickets normalize shared result,
usage, warning, and telemetry contracts without forcing every modality through
chat or pulling orchestration into ReqLLM.

## Streamlining audit of all 42 proposals

The July 16 audit checked every issue against current `main`, the
`reqllm_next` prototype, and the one-PR/backward-compatibility rules.

| Original order | Issue | Disposition | Reason |
| ---: | --- | --- | --- |
| 1 | #831 | Keep | Compatibility and ReqLLM/Jido ownership must precede refactors. |
| 2 | #832 | Narrow | Inventory existing tests and fill contract gaps instead of duplicating the suite. |
| 3 | #833 | Keep | Accepted tuple defaults are currently discarded and need one boundary fix. |
| 4 | #834 | Keep | Mechanical catalog extraction removes duplicated Mix-task routing. |
| 5 | #835 | Keep | Scenario enrichment remains separate from the mechanical extraction. |
| 6 | #836 | Narrow | Evidence comes first; support labels remain conservative tooling output. |
| 7 | #837 | Keep | Sparse live drift detection complements replay without changing normal CI. |
| 8 | #838 | Narrow | Use one request-plan value, not the prototype's profile/mode/surface/plan stack. |
| 9 | #839 | Expand coherently | The existing OpenAI dispatcher owns Chat and Responses selection, so migrate both together. |
| 10 | #840 | Consolidate into #839 | A second OpenAI surface-selection PR would duplicate the same dispatcher change. |
| 11 | #841 | Keep | Anthropic is the useful non-OpenAI parity proof. |
| 12 | #842 | Narrow | Expose a small experimental diagnostic map, not internal planner structs or raw bodies. |
| 13 | #843 | Recast | Canonical reasoning options already exist; harden translation and warning propagation. |
| 14 | #844 | Keep | Provider-keyed options are a useful additive bridge while flat provider options remain. |
| 15 | #845 | Narrow | Add computed projections without changing Response fields, defaults, or legacy JSON. |
| 16 | #846 | Narrow | Add an event projection over one stream, not a second consumable stream field. |
| 17 | #847 | Recast | Consolidate the existing ChunkAccumulator and ResponseBuilder paths. |
| 18 | #848 | Keep | The buffered OpenAI Responses decoder still diverges from its stream builder. |
| 19 | #849 | Keep | The buffered Anthropic decoder still diverges from its stream builder. |
| 20 | #850 | Narrow | Add total and idle semantics around existing request timeouts rather than duplicate knobs. |
| 21 | #851 | Keep | Output descriptors are a high-value additive API aligned with the AI SDK. |
| 22 | #852 | Narrow | Make current extraction/repair visible; avoid a general coercion or hidden model-repair framework. |
| 23 | #853 | Recast | Harden the existing tool structs instead of creating parallel exchange types. |
| 24 | #854 | Narrow | Add only matched-call/result helpers on top of existing Context operations. |
| 25 | #855 | Recast | Document and test the public one-call boundary; the actual Jido adapter stays in Jido. |
| 26 | #856 | Narrow | Extract measured seams from current OpenAI modules, not four new behavior hierarchies. |
| 27 | #857 | Already satisfied | Providers.register/1, :custom_providers, inline models, docs, and tests are on main. |
| 28 | #858 | Defer | A four-stage global/per-call middleware framework is speculative and would expand the V1 runtime surface. |
| 29 | #859 | Keep | A later ADR can decide whether the prototype manifest earned its complexity. |
| 30 | #860 | Narrow | Stabilize a small telemetry core and explicitly leave provider/detail events experimental. |
| 31 | #861 | Keep | Read-only diagnostics directly improve support and onboarding. |
| 32 | #862 | Consolidate into #842 | Route and option-key summaries are useful; encoded request previews duplicate encoding and raise leak risk. |
| 33 | #863 | Narrow | Keep the ledger and only static checks with low false-positive risk. |
| 34 | #864 | Recast | Add explicit ownership metadata only for opt-in references; legacy ContentPart values and encoding remain exact. |
| 35 | #865 | Keep | OpenAI upload lifecycle is valuable and correctly provider-scoped. |
| 36 | #866 | Already satisfied | Image APIs already return Response plus ContentPart, usage, provider metadata, and revised prompts. |
| 37 | #867 | Recast | Return opt-in detailed metadata without expanding Transcription.Result. |
| 38 | #868 | Recast | Return opt-in detailed metadata without expanding Speech.Result. |
| 39 | #869 | Already satisfied | RerankResponse already preserves indices, sorting, batching, warnings, usage/cost, and telemetry. |
| 40 | #870 | Recast | Preserve exact OCR success, error, and bang behavior while hardening internal classification, telemetry, and evidence. |
| 41 | #871 | Narrow | Canonicalize only exact event overlap and retain OpenAI-native session semantics. |
| 42 | #872 | Keep | The boundary document prevents provider-native depth from becoming an agent runtime. |

## Execution cadence

The [V1 execution goal](V1_EXECUTION_GOAL.md) is the delivery charter. Although
the backlog records dependency opportunities, implementation is intentionally
serial:

1. Work the first open, unblocked issue in the priority order above.
2. Take one issue through implementation, review, hardening, merge, and green
   post-merge `main` checks before starting another.
3. Pull the next unblocked active ticket from #831–#872 only after the current
   delivery cycle is complete.
4. Track completion and scope decisions in #829.
5. Treat the 36 active tickets recorded above as the complete V1 roadmap. Any
   issue beyond this set needs an explicit scope expansion recorded in #829.

## V1 completion gates

- All new contracts have executable public or conformance tests.
- Legacy inputs and projections remain covered until V2.
- Provider adoption occurs by named surface with before/after scenario parity.
- No V1 ticket introduces a Jido runtime dependency or model-call loop.
- Deprecations are present in the ledger and audit tooling.
- V2 default changes remain opt-in throughout V1.
- Support claims are derived from current evidence rather than catalog presence.
