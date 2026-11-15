---
title: Extract the internal ReqLLM model resolver
type: implementation-plan
date: 2026-11-15
last_reviewed: 2026-11-15
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready
domain: software
execution: code
product_contract_source: direct-request
---

# Extract the internal ReqLLM model resolver

## Goal Capsule

- Objective: Extract the current model-resolution rules into an internal
  `ReqLLM.ModelResolver` in one pull request, with no public behavior change.
- Means: Keep `ReqLLM.model/1` and `ReqLLM.model!/1` as the compatibility shell.
  Move resolution decisions into one effect-free module that returns warnings
  as data.
- Authority: The direct request authorizes local implementation, offline checks,
  a branch, a commit, a push, and a draft pull request. It does not authorize a
  live provider call, merge, release, or public behavior change.
- Stop conditions: Stop if exact public parity fails, the resolver needs a new
  dependency, or implementation needs a Router, RequestPlan, Evaluation, or
  provider contract change.
- Next executor: The current ReqLLM implementation goal. The draft pull request
  remains blocked from merge until the roadmap dependency is satisfied.

## Product Contract

### Summary

ReqLLM must have one internal owner for static model resolution. Existing callers
must continue to use the same public API and get the same models, errors, warnings,
wire metadata, pricing metadata, and provider-facing IDs.

### Problem Frame

The public `ReqLLM` facade currently owns model parsing, catalog lookup, inline
model validation, enrichment, provider fallbacks, wire inference, Google pricing
repair, warning policy, and warning output. This makes the facade a policy module
and contributes to a broad dependency cycle.

The extraction has a large consumer surface but a small safe change surface.
There are 93 direct production calls to `ReqLLM.model/1` or `model!/1` in 39
files. Those calls do not need to change in this pull request.

### Actors

- Application authors who call `ReqLLM.model/1`, `model!/1`, or an operation that
  accepts a model specification.
- Provider authors whose modules use the public model functions or inline model
  specifications.
- ReqLLM maintainers who need one internal owner for model-resolution rules.

### Requirements

- **R1:** Keep the documented names, arities, input forms, result tuples, error
  terms, raised exceptions, warning text, and warning count of `ReqLLM.model/1`
  and `ReqLLM.model!/1`.
- **R2:** Keep string, two-element tuple, three-element tuple, plain-map, and
  `%LLMDB.Model{}` input behavior. A three-element tuple continues to use only
  its model identity during `model/1` resolution.
- **R3:** Keep catalog aliases, provider prefixes, suffixes, canonical IDs, and
  `provider_model_id` routing values.
- **R4:** Keep inline-model validation, string-key conversion, enrichment,
  legacy `model` field synchronization, and TypeSafe generation restrictions.
- **R5:** Keep OpenAI Responses inference, OpenAI Codex wire metadata, Google
  pricing normalization, and all current provider fallback rules.
- **R6:** Make `ReqLLM.ModelResolver` free of output effects and application
  warning-policy reads. It returns warning strings as data. The public facade
  applies the current configuration and emits each warning once.
- **R7:** Leave all current production callers on the public facade. Do not
  change Router, RequestPlan, diagnostics, Evaluation, operations, providers,
  billing, telemetry, or result behavior.
- **R8:** Keep the new module internal with `@moduledoc false`. Do not add a
  dependency or change LLMDB.
- **R9:** Do not add a dependency from `ReqLLM.ModelResolver` back to the public
  `ReqLLM` module. Do not increase the current compile-connected cycle.

### Key Flows

#### Current flow

```text
ReqLLM.model/1
  -> parse or normalize input
  -> query LLMDB and the provider registry
  -> apply fallback, enrichment, wire, and pricing rules
  -> read warning configuration and call IO.warn/1 when needed
  -> return the public result tuple
```

#### Target flow

```text
ReqLLM.model/1
  -> ReqLLM.ModelResolver.resolve/2 with the provider lookup dependency
       -> parse or normalize input
       -> query LLMDB and use the supplied provider lookup
       -> apply the same fallback, enrichment, wire, and pricing rules
       -> return model plus warning strings, or the existing error
  -> apply warn_unverified_models configuration
  -> emit each warning once
  -> return the same public result tuple

ReqLLM.model!/1
  -> ReqLLM.model/1
  -> return the model or raise the same error
```

### Acceptance Examples

1. A catalog string such as `"openai:gpt-4o"` returns the same fully enriched
   `%LLMDB.Model{}` and OpenAI wire protocol before and after the extraction.
2. Equivalent tuple identities return equal models. Three-element tuple options
   do not change model identity resolution.
3. An explicit inline map does not emit an unverified-model warning.
4. An unknown model for a registered provider emits the current warning once.
   `warn_unverified_models: false` suppresses it without changing the result.
5. An invalid inline map returns the same exception struct, tag, context, and
   message. `model!/1` raises that same exception.
6. Bedrock-style prefixes and suffixes keep the same provider-facing ID.
7. Google tiered prices remain equal and do not gain duplicate components after
   a second resolution pass.
8. Router-returned models, RequestPlan double resolution, and Evaluation catalog
   rules remain unchanged because their callers do not change in this pull
   request.

### Success Criteria

- The final production diff changes only the public facade and adds the internal
  resolver module.
- All 93 production call sites remain unchanged.
- Focused model, Router, plan, Evaluation, host, and provider-extension checks
  pass without live provider access.
- The full default test suite and repository quality gate pass.
- The final source has one active model-resolution implementation.

### Scope Boundaries

Included:

- The private resolution logic and constants now in `lib/req_llm.ex`.
- A new internal `ReqLLM.ModelResolver` module.
- Warning-as-data handling between the resolver and public facade.
- Focused contract coverage for gaps found during the blast-radius review.
- Compile dependency checks for the new module.

Excluded:

- Migration of any current `ReqLLM.model/1` or `model!/1` caller.
- Router result normalization or Router-aware planning.
- RequestPlan construction, its current second resolution pass, or diagnostics.
- Evaluation catalog policy.
- Provider, protocol, wire, transport, response, billing, or telemetry redesign.
- Extraction of provider-specific policy modules.
- Strict dependency injection of catalog snapshots.
- Public guides, public types, provider callbacks, new dependencies, LLMDB
  changes, and live provider calls.

### Key Decisions

- “Pure” means no output side effect and no application warning-policy read.
  Catalog reads remain allowed. The facade supplies the provider lookup to
  keep the resolver out of the existing compile-connected cycle.
- Warning strings are the internal warning result. This keeps the exact current
  text and avoids a new warning model.
- The public facade stays the only supported model-resolution entry point for
  current callers.
- Current provider-specific resolution rules move unchanged. Their later
  decomposition is separate architecture work.

### Rejected Alternatives

- Strict referential purity with an injected catalog snapshot. This increases
  the change surface and is not needed to remove output effects.
- Migrate all callers to `ReqLLM.ModelResolver`. This changes 39 production
  files and removes the compatibility shell from internal use too early.
- Normalize Router results in this pull request. Router behavior belongs to
  V2-04 and can change observable behavior.
- Split OpenAI, Google, and provider fallback policy at the same time. This
  makes parity defects hard to locate.
- Keep two active resolvers after the pull request. This creates duplicate
  policy and maintenance risk.

### Dependencies

- Roadmap step V2-00 is draft pull request 1271 and is the base of this stacked
  implementation pull request.
- Roadmap step V2-01 does not have a pull request. The focused compatibility
  coverage in this change supplies implementation evidence, but this stacked
  pull request remains blocked from merge until that roadmap dependency is
  satisfied.
- Current ReqLLM code and tests remain the source for implemented behavior.
- `llm_db` remains at the version selected in `mix.lock`; no dependency change
  is part of this work.

### Outstanding Questions

None block planning. Strict referential purity and provider-policy extraction
remain deferred architecture questions. They do not belong in this pull request.

### Sources

- [Accepted V2 direction](../decisions/2026-11-15-v2-direction.md)
- [V2 scope](v2-scope.md)
- [V2 roadmap](v2-roadmap.md)
- [V1 compatibility policy](../../COMPATIBILITY.md)
- [Current public facade](../../lib/req_llm.ex)
- [Current RequestPlan](../../lib/req_llm/request_plan.ex)
- [Current Router](../../lib/req_llm/router.ex)
- [Public model contracts](../../test/req_llm_test.exs)
- [Model prefix contracts](../../test/req_llm/model_prefix_resolution_test.exs)

## Planning Contract

### Product Contract Preservation

Product Contract unchanged.

This plan implements V2-03 only. It preserves the compatibility shell in the
accepted V2 direction. It does not implement V2-04 planning changes or later
provider and result work.

The final public model functions stay in `ReqLLM`. Existing operation modules,
providers, Mix tasks, tests, and third-party code continue to call those
functions. The pull request changes ownership of the implementation, not the
public contract.

### Current System

`ReqLLM.model/1` starts at `lib/req_llm.ex:316`. Its private helper block extends
through inline model error construction near `lib/req_llm.ex:950`.

The block currently owns:

- LLMDB catalog and alias resolution;
- map and struct enrichment;
- inline model validation;
- prefix and provider-facing ID preservation;
- OpenAI and OpenAI Codex wire metadata;
- Google tiered pricing repair;
- provider-specific and generic fallbacks;
- unverified-model warning policy and output; and
- public error construction.

Downstream systems use more than the resolved model ID. RequestPlan uses wire
metadata, response builders use provider and wire data, and billing uses the
normalized prices. A small resolver difference can therefore change the wire
request, response decoding, telemetry metadata, or cost.

RequestPlan currently calls `ReqLLM.model/1` twice in
`lib/req_llm/request_plan.ex:248`. Generation accepts Router results without a
second general normalization pass in `lib/req_llm/generation.ex:434`.
Evaluation also has stricter catalog rules in `lib/req_llm/evaluation.ex:154`.
These differences are current behavior and stay unchanged.

The delegated blast-radius review found 93 direct production calls in 39 files
and 976 direct test calls in 153 files. The focused baseline suite passed 128
tests with no failures. The full default `mix test` command exited successfully,
and `mix test --failed` reported no failed tests. The review used no live
provider APIs and left the worktree clean.

### Target System

`ReqLLM.ModelResolver` owns static model-resolution decisions. It returns either
the current error or a resolved model with zero or more warning strings. It does
not read `:warn_unverified_models` and does not write to standard error.

`ReqLLM.model/1` becomes a small compatibility adapter. It calls the resolver,
applies the existing warning configuration, emits warnings, and projects the
internal result to the unchanged public tuple. `ReqLLM.model!/1` continues to
call `ReqLLM.model/1`.

The facade passes `ReqLLM.Providers.get/1` to the resolver as an internal
lookup function. The resolver does not call `ReqLLM.Providers`,
`ReqLLM.provider/1`, `ReqLLM.model/1`, or `ReqLLM.model!/1`. Its types do not
refer to `ReqLLM.static_model_input()` because that would add a compile
dependency back to the facade.

The resolver can read LLMDB and use the supplied provider lookup. It is
deterministic for a fixed catalog and lookup result. Strict catalog snapshot
injection remains outside this pull request.

### Key Technical Decisions

#### KTD1: Use operational purity

- **Decision:** The resolver has no output effect and does not read application
  warning policy. LLMDB reads remain allowed. The facade injects the provider
  lookup.
- **Reason:** R6 requires warning effects outside the resolver. Strict snapshot
  injection would make a small extraction materially larger.
- **Rejected alternative:** Inject complete catalog and provider snapshots.
  This needs a new dependency interface and more integration changes.
- **Consequences:** Resolver tests must control catalog and registry state and
  supply the provider lookup. The resolver is deterministic only for fixed
  dependency state.
- **Governs:** R6, R8, U2.

#### KTD2: Return exact warning strings as data

- **Decision:** The internal success result includes a list of current warning
  strings. The public facade applies configuration and emits the strings once.
- **Reason:** Exact warning text and count are protected behavior under R1.
- **Rejected alternative:** Add a structured warning type in this pull request.
  That adds translation rules without a current consumer need.
- **Consequences:** A later structured warning design must preserve this public
  projection.
- **Governs:** R1, R6, U1, U2.

#### KTD3: Keep all callers on the public facade

- **Decision:** Do not change the 93 production call sites.
- **Reason:** The standalone pull request only changes implementation ownership.
  Caller migration has a much larger blast radius and is not needed for V2-03.
- **Rejected alternative:** Move operation and provider callers directly to the
  new resolver.
- **Consequences:** This pull request does not remove the full repository
  dependency cycle. It establishes the boundary for later migration.
- **Governs:** R7, U2, U3.

#### KTD4: Move current semantic policy as one block

- **Decision:** Move OpenAI wire inference, Google pricing repair, inline model
  rules, and provider fallbacks unchanged into the resolver.
- **Reason:** Partial ownership would leave resolution policy in two modules and
  make parity defects hard to isolate.
- **Rejected alternative:** Split each provider policy into a new module during
  the extraction.
- **Consequences:** `ReqLLM.ModelResolver` is initially a large policy module.
  Later work can split policy after this boundary has contract evidence.
- **Governs:** R3, R4, R5, U2.

#### KTD5: Prevent a back-edge to the facade

- **Decision:** The resolver uses direct internal dependencies and local types.
  It never calls or types against `ReqLLM`.
- **Reason:** R9 prevents the extraction from making the current dependency
  cycle worse.
- **Rejected alternative:** Move the private functions unchanged while they
  continue to call `ReqLLM.provider/1` or `ReqLLM.model/1`.
- **Consequences:** Recursive fallback calls stay inside the resolver. Provider
  availability uses the lookup function that the facade supplies.
- **Governs:** R9, U2, U3.

### System Boundaries and Change Surface

| Surface | Current contract | Planned change | Compatibility or risk |
| --- | --- | --- | --- |
| `lib/req_llm.ex` | Public model API and private resolution policy | Keep docs, types, facade functions, warning policy, and warning output; remove private resolution policy | Exact public tuple, exception, and warning parity is required |
| `lib/req_llm/model_resolver.ex` | Does not exist | Add one internal effect-free resolution owner | Must not depend back on `ReqLLM` |
| `test/req_llm_test.exs` | Main public model contracts | Keep all tests; add only missing exact warning or error cases if V2-01 does not cover them | Tests must keep public behavior as the main proof |
| `test/req_llm/model_prefix_resolution_test.exs` | Prefix, alias, suffix, and transport route contracts | Keep unchanged unless a missing parity case needs one focused assertion | Provider-facing ID changes are high risk |
| New internal resolver test | Does not exist | Test warning-as-data, no output effect, recursion, and idempotence | Internal tests do not replace public contracts |
| Router, RequestPlan, diagnostics, Evaluation, operations, providers | Current consumers of `ReqLLM.model/1` or resolved model data | No source change | Any required change here stops the pull request for rescoping |
| LLMDB and dependencies | Current package contracts | No change | A dependency change is outside scope |

There is no persisted data, schema, deployment, authentication, authorization,
network, process lifecycle, or concurrency change.

### Implementation Units

#### U1: Lock resolver compatibility gaps

- **Outcome:** Focused tests state every model-resolution behavior that is not
  already explicit in the V2-01 compatibility matrix.
- **Requirements:** R1-R5.
- **Dependencies:** Focused baseline evidence is available. V2-01 remains a
  merge gate for the stacked pull request.
- **Affected surfaces:** `test/req_llm_test.exs`,
  `test/req_llm/model_prefix_resolution_test.exs`, and a new
  `test/req_llm/model_resolver_test.exs` that first calls only the public facade.
- **Implementation direction:** Add a table-driven public contract for accepted
  input forms, exact errors, exact warning text and count, fallback families,
  wire metadata, Google pricing idempotence, and provider-facing IDs. Reuse the
  current LLMDB store snapshot pattern for tests that replace catalog state.
  Do not duplicate cases that V2-01 already proves.
- **Test scenarios:** Catalog strings; colon and at formats; two- and
  three-element tuples; atom-key and string-key maps; model structs; invalid
  inputs; OpenAI Codex, GitHub Copilot, Mistral, MiniMax, TypeSafe, and generic
  registered-provider fallbacks; warning enabled and disabled; prefix and
  suffix preservation; second-pass idempotence.
- **Verification:** Run the new or changed test file plus
  `test/req_llm_test.exs` and
  `test/req_llm/model_prefix_resolution_test.exs`.
- **Completion signal:** Each protected resolver rule has one direct public
  assertion, and the focused tests pass before production code moves.

#### U2: Extract and activate `ReqLLM.ModelResolver`

- **Outcome:** One internal module owns static model resolution, and the public
  facade projects its result with unchanged behavior.
- **Requirements:** R1-R9.
- **Dependencies:** U1.
- **Affected surfaces:** `lib/req_llm.ex`, new
  `lib/req_llm/model_resolver.ex`, and new or existing focused resolver tests.
- **Implementation direction:** Move the private model clauses, constants, and
  helpers into the new internal module. Use a local input type. Return warning
  strings with successful resolution. Keep application warning configuration
  and `IO.warn/1` in the public facade. Replace recursive public facade calls
  with private resolver calls. Pass `ReqLLM.Providers.get/1` from the facade as
  the resolver's provider lookup. Keep `model!/1` through `model/1`. Switch the
  facade and remove the old private implementation in the same integration
  unit. Do not leave two active resolver paths. Do not add comments inside
  function bodies.
- **Test scenarios:** Direct resolver calls produce no standard-error output;
  warning data is exact; the facade emits or suppresses it once; successful and
  failed public results match U1; second resolution is idempotent; provider
  fallback recursion does not re-enter `ReqLLM`.
- **Verification:** Run U1 tests, the new internal resolver tests, compilation
  with warnings as errors, and the direct xref trace for the new module.
- **Completion signal:** `ReqLLM.model/1` contains only compatibility projection
  and warning effects. All moved private helpers are absent from `ReqLLM`.

#### U3: Prove the standalone integration boundary

- **Outcome:** The complete repository proves that the extraction changed no
  supported caller behavior and added no facade back-edge.
- **Requirements:** R1-R9.
- **Dependencies:** U2.
- **Affected surfaces:** Test and static-analysis results only. Product code
  changes belong to U2.
- **Implementation direction:** Run focused caller contracts before broad
  checks. Compare the compile-connected cycle output with the pre-change
  baseline. Confirm that all current production call sites still call the
  public facade. Confirm that no public guide, type, callback, dependency, or
  lockfile changed.
- **Test scenarios:** Router, RequestPlan, public plan diagnostic, Evaluation,
  host integration, provider extension, and the full default suite.
- **Verification:** Run all gates in the Verification Contract.
- **Completion signal:** Every gate passes, the final diff stays inside the
  planned file boundary, and no material behavior question remains.

### Work Graph

- Initial frontier: U1, with the focused baseline evidence from the blast-radius
  review.
- Dependency path: `U1 -> U2 -> U3`.
- Parallel work: None. U2 needs the contract evidence from U1. U3 needs the
  final U2 source state.
- Critical path: U1, U2, U3.
- Final integration unit: U3.

### Verification Contract

Run all commands from `/Users/mhostetler/Source/ReqLLM/req_llm`.

| Gate | Applies to | Evidence | Done signal |
| --- | --- | --- | --- |
| Public resolver contract | U1-U2 | Public model, prefix, and tuple tests | Exact results, errors, warnings, wire data, pricing, and IDs pass |
| Internal effect boundary | U2 | New resolver unit tests | Resolver emits no output and returns warning strings as data |
| Caller parity | U3 | Router, plan, Evaluation, host, and provider-extension tests | Existing caller behavior passes without source changes |
| Dependency direction | U2-U3 | xref trace and cycle comparison | No `ModelResolver -> ReqLLM` edge and no larger cycle |
| Repository regression | U3 | Full test and quality commands | All offline gates pass |
| Diff boundary | U3 | Git diff and dependency files | Only planned source and tests changed; no dependency or public docs change |

Focused contract gate:

```sh
mix test \
  test/req_llm/model_resolver_test.exs \
  test/req_llm_test.exs \
  test/req_llm/model_prefix_resolution_test.exs \
  test/req_llm/tuple_model_options_test.exs \
  test/req_llm/router_test.exs \
  test/req_llm/request_plan_test.exs \
  test/req_llm/plan_test.exs \
  test/req_llm/evaluation_test.exs \
  test/contracts/host_integration_contract_test.exs \
  test/contracts/provider_extension_contract_test.exs
```

Static and dependency gates:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix xref trace lib/req_llm/model_resolver.ex --no-compile
mix xref graph --format cycles --label compile-connected --no-compile
```

The cycle command is a comparison gate, not a zero-cycle gate. The repository
already has one compile-connected cycle. The pull request must not add a back-edge
to `ReqLLM`, add the resolver to a larger cycle, or increase the cycle count.

Repository gates:

```sh
mix test
mix quality
```

No command uses `LIVE=true`. No provider credential is required.

Requirement traceability:

| Requirement | Units | Verification |
| --- | --- | --- |
| R1-R2 | U1, U2, U3 | Public resolver, tuple, and full-suite gates |
| R3 | U1, U2, U3 | Prefix tests and caller parity |
| R4-R5 | U1, U2, U3 | Resolver matrix, plan tests, billing-sensitive assertions, full suite |
| R6 | U2 | Internal effect-boundary tests |
| R7 | U2, U3 | Caller searches, focused caller tests, final diff |
| R8 | U2, U3 | Compile, quality, dependency and diff checks |
| R9 | U2, U3 | xref trace and compile-connected cycle comparison |

### Rollout and Recovery

There is no runtime migration, stored-data change, deployment order, or feature
flag. Activation occurs when the public facade starts calling the new internal
resolver.

The rollback is one pull-request revert because all callers keep the public
facade. If parity fails before merge, restore the old private implementation and
remove the new module. Do not ship two active resolvers as a fallback.

### Risks and Assumptions

| Risk or assumption | Control |
| --- | --- |
| “Pure” can mean strict referential purity | KTD1 defines the bounded meaning for this pull request |
| Warning movement can remove or duplicate output | Return exact strings as data and test enabled, disabled, and exact count |
| RequestPlan resolves a model twice | Keep the caller unchanged and test second-pass idempotence |
| OpenAI wire inference can change request and decoder selection | Keep rules unchanged and run plan plus provider tests |
| Google pricing repair can duplicate components | Test equality after a second resolution pass |
| Prefix or suffix loss can change provider routes | Keep model-prefix tests and transport route assertions |
| String and atom providers use different validation paths | Include both in the contract matrix |
| TypeSafe fallback changes capabilities | Add an exact capability assertion |
| Resolver naming can be confused with `LLMDB.ModelResolver` | Use fully qualified names where both modules appear; do not alias both |
| Existing compile cycle can hide a new back-edge | Compare xref output and inspect the new module trace |
| V2-01 can already contain some planned tests | U1 adds only missing cases and does not duplicate the matrix |

The plan assumes the current public behavior is intentional because the accepted
V2 direction requires stable observable behavior. A defect discovered during
implementation is not corrected in this pull request. Record it for a separate
behavior-change decision.

### Open Planning Decisions

None.

Deferred decisions:

- Strict referential purity through injected catalog and provider snapshots.
- Provider-specific policy modules for OpenAI, Google, and fallback families.
- Direct internal caller migration away from the public facade.
- Router normalization, RequestPlan consolidation, and Evaluation migration.

### Definition of Done

- U1, U2, and U3 meet their completion signals.
- `ReqLLM.ModelResolver` is the only active owner of static model resolution.
- The resolver has no output effect, application warning-policy read, or
  dependency back to `ReqLLM`.
- `ReqLLM.model/1` and `model!/1` keep all protected inputs and outputs.
- All 93 production call sites remain unchanged.
- Router, RequestPlan, diagnostics, Evaluation, providers, billing, telemetry,
  and public documentation remain outside the production diff.
- Exact warnings, errors, wire metadata, prices, and provider-facing IDs pass
  focused contract tests.
- The xref comparison shows no larger compile-connected cycle.
- `mix test` and `mix quality` pass without live provider access.
- The final diff contains no new dependency, lockfile change, public API change,
  or comments inside function bodies.

### Planning Sources

- [Accepted V2 direction](../decisions/2026-11-15-v2-direction.md)
- [V2 roadmap step V2-03](v2-roadmap.md)
- [V2 scope and compatibility risks](v2-scope.md)
- [ReqLLM compatibility policy](../../COMPATIBILITY.md)
- [Provider extension decision](../../guides/provider-extension-decision.md)
- [Public model implementation](../../lib/req_llm.ex)
- [RequestPlan model resolution](../../lib/req_llm/request_plan.ex)
- [Generation Router boundary](../../lib/req_llm/generation.ex)
- [Evaluation model policy](../../lib/req_llm/evaluation.ex)
- [Public model tests](../../test/req_llm_test.exs)
- [Prefix-resolution tests](../../test/req_llm/model_prefix_resolution_test.exs)
- [Router tests](../../test/req_llm/router_test.exs)
- Delegated read-only blast-radius review, thread
  `01a1e0f1-00ca-7040-90d8-57ac981ddf0c`, 2026-11-15.

## Adapter Results

- Markdown: canonical at
  `docs/plans/2026-11-15-1449-model-resolver-extraction-plan.md`
- HTML: not requested
- Beadwork: not requested
