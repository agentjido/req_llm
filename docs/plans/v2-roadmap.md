---
title: ReqLLM V2 architecture consolidation roadmap
status: active
last-reviewed: 2026-11-15
---

# ReqLLM V2 architecture consolidation roadmap

## Destination

Release ReqLLM V2 with one consolidated internal architecture and the same
public API and observable behavior.

The [V2 scope](v2-scope.md) owns the delivery boundary. The
[V2 direction](../decisions/2026-11-15-v2-direction.md) owns the design rules.
This plan owns the migration sequence and completion checks.

## Migration rule

Use an expand, migrate, and remove sequence:

1. Add contract evidence and expand an existing internal boundary.
2. Migrate one bounded caller group.
3. Prove equal behavior with contracts and fixtures.
4. Remove the old internal branch only after all callers move.

Each migration unit is one focused pull request. A unit keeps the old path
until its direct checks pass. Before old code is removed, rollback means that
the changed caller group can return to the old path in one revert.

Do not mix an internal architecture change with a public behavior change.

No step in this plan authorizes a commit, push, issue change, live provider
call, publication, or release.

## Small steps

| Step | Status | Change | Direct completion check | Old path and rollback | Depends on |
| --- | --- | --- | --- | --- | --- |
| V2-00 | In review | Create the repository-owned V2 direction, scope, source map, and roadmap. | Documentation links, source claims, boundary, and risk controls pass review. | Documentation only. Revert the documentation commit. | None |
| V2-01 | Waiting | Build the compatibility matrix. Add missing Router, provider wrapper, value-shape, stream, telemetry, and host contracts. Reconcile the migration ledger with the stable-API scope. | The focused contract matrix passes and the ledger does not imply a planned public removal or default change. | No runtime switch. Revert the contract and ledger commit. | V2-00 merged |
| V2-02 | Waiting | Extend `ReqLLM.ModelOperation` with one mapping for operation, option schema, evidence category, runtime action, and result policy. Remove repeated maps that it replaces. | Catalog, option, model-input, and operation tests pass with equal public behavior. | Keep old maps until all readers use the descriptor. Revert readers to the old maps. | V2-01 |
| V2-03 | Waiting | Extract an internal model resolver from the public `ReqLLM` module. Keep every supported form, warning, fallback, and error. | Strings, tuples, plain maps, and `%LLMDB.Model{}` values produce equal results and errors. | Keep public delegates and old tests. Revert delegates to the old private functions. | V2-01 |
| V2-04 | Waiting | Define Router-aware planning input and expand `RequestPlan` for all operation result policies. Migrate one buffered generation operation as proof. | Router and direct models plan correctly. The selected operation keeps equal request, result, error, and telemetry behavior. | Keep its old constructor and call site until checks pass. Revert that call site. | V2-02, V2-03 |
| V2-05A | Waiting | Migrate remaining buffered text and object generation planning. | Generation contracts and recorded fixtures pass. | Keep old constructors until the group passes. Revert generation call sites. | V2-04 |
| V2-05B | Waiting | Migrate embedding and rerank planning. Keep their current result policies. | Embedding and rerank contracts, result values, and fixtures pass. | Keep old constructors until the group passes. Revert embedding and rerank call sites. | V2-05A |
| V2-05C | Waiting | Migrate image-generation planning. Keep the current image result policy. | Image request, result, error, and fixture checks pass. | Keep old image planning until checks pass. Revert image call sites. | V2-05B |
| V2-05D | Waiting | Migrate speech planning. Keep the current speech result policy. | Speech request, result, error, and fixture checks pass. | Keep old speech planning until checks pass. Revert speech call sites. | V2-05C |
| V2-05E | Waiting | Migrate transcription planning. Keep the current transcription result policy. | Transcription request, result, error, and fixture checks pass. | Keep old transcription planning until checks pass. Revert transcription call sites. | V2-05D |
| V2-05F | Waiting | Migrate OCR planning. Keep the current OCR result policy. | OCR request, result, error, and fixture checks pass. | Keep old OCR planning until checks pass. Revert OCR call sites. | V2-05E |
| V2-05G | Waiting | Migrate video generation, query, wait, retrieve, and upload planning. | Video task, polling, result, and error contracts pass. | Keep old video planning until all video operations pass. Revert video call sites. | V2-05F |
| V2-05H | Waiting | Migrate compaction planning. | Compaction contracts and fixtures pass. | Keep old compaction planning until checks pass. Revert compaction call sites. | V2-05G |
| V2-05I | Waiting | Migrate evaluation planning. | Evaluation contracts and fixtures pass. | Keep old evaluation planning until checks pass. Revert evaluation call sites. | V2-05H |
| V2-05J | Waiting | Migrate custom provider stream operations. | Custom-provider stream contracts and terminal behavior pass. | Keep custom stream dispatch until checks pass. Revert custom stream call sites. | V2-05I |
| V2-06 | Waiting | Add internal `ResolvedExecution` through `Provider.Adapter`. Preserve hosting and wire identities. Select route, authentication, protocol, wire adapter, transport, and result policy before execution. | Current providers, Azure, Vertex, Bedrock, OpenRouter, and custom providers select equal execution behavior. | Keep adapter support for current provider modules. Revert Runtime to the current adapter result. | V2-05J |
| V2-07 | Waiting | Split `Provider.Defaults` by responsibility behind its complete macro, callback, and helper wrapper. | Provider-extension contracts and representative provider fixtures pass. No public helper or callback changes. | Keep every public entry point as a delegate. Revert delegates to the original module functions. | V2-01 |
| V2-08 | Waiting | Move response-builder selection into `ResolvedExecution`. Define one internal reduction contract for buffered and streamed generation output. | Buffered and streamed generation responses remain equal for each protocol family. Non-generation result policies remain unchanged. | Keep late builder selection until all generation checks pass. Revert generation execution to late selection. | V2-06, V2-07 |
| V2-09A | Waiting | Migrate OpenAI and OpenAI-compatible generation output reduction. | Response, chunk, event, ordering, usage, warning, error, and cancellation fixtures pass. | Keep the current OpenAI reducer until checks pass. Revert OpenAI dispatch. | V2-08 |
| V2-09B | Waiting | Migrate Anthropic generation output reduction. | Anthropic buffered and stream compatibility fixtures pass. | Keep the current Anthropic reducer until checks pass. Revert Anthropic dispatch. | V2-09A |
| V2-09C | Waiting | Migrate Google generation output reduction. | Google buffered and stream compatibility fixtures pass. | Keep the current Google reducer until checks pass. Revert Google dispatch. | V2-09B |
| V2-09D | Waiting | Migrate remaining protocol-family generation output reduction. | Each remaining family passes its recorded response and stream fixtures. | Keep each family reducer until its checks pass. Revert only that family dispatch. | V2-09C |
| V2-10 | Waiting | Move first-party Context reads to accessors while keeping public list storage and value behavior. | JSON, term storage, equality, inspection, `Enumerable`, `Collectable`, order, and provider input remain equal. | Keep list storage and public fields. Revert internal callers to direct list reads. | V2-01 |
| V2-11 | Waiting | Remove old constructors, maps, late dispatch branches, and reducers only after all callers have moved. Repair stale architecture documentation. | Search and contract evidence show one active internal path with no public contract removal. | Remove one old branch per pull request. Revert that removal if a missed caller appears. | V2-09D, V2-10 |
| V2-12 | Waiting | Run release-candidate evidence and prepare stable-API release notes. | Full tests, `mix quality`, docs, package dry-run, recorded fixtures, and CI pass. Release notes list preserved contracts, internal changes, and known risks. | No runtime migration. Stop the release and keep the last verified V1 release available. | V2-11 |

The current frontier is V2-00. V2-01 becomes ready after V2-00 is reviewed and
merged.

After V2-01, V2-02, V2-03, V2-07, and V2-10 can proceed in parallel. The main
execution path is V2-02 and V2-03 through V2-09D, V2-11, and V2-12.

## Risk review points

- Review planning after V2-04 before broad operation migration.
- Review provider compatibility after V2-06 and V2-07.
- Review response and stream compatibility after each V2-09 unit.
- Review the scope of the change before V2-11 removes old internal paths.
- Review the complete compatibility matrix before V2-12 release work.

## Deferred beyond this roadmap

- A new public provider extension contract.
- A compile-time provider manifest or DSL.
- Canonical events as the raw public stream.
- Context storage changes.
- Provider or operation support reduction.
- Any public removal or default change from historical issue 830.

These items need a separate owner decision and new scope. They are not implied
by the V2 name.

The [ecosystem hardening ideas](../inbox/2026-11-15-v2-ecosystem-hardening-ideas.md)
remain inbox candidates. They do not add steps to this roadmap.

## V2 completion gate

- All current public operation families remain available.
- Router and all supported model input forms remain available.
- Current providers, wrapper platforms, and custom providers keep their
  supported behavior.
- Current values, streaming, options, validation, telemetry, and provider
  extension contracts remain available.
- One internal planning and execution path handles all operations.
- One internal reduction contract handles buffered and streamed generation
  output. Other operations keep their explicit result policies.
- Old internal branches are removed with direct migration evidence.
- The full test suite and `mix quality` pass.
- Documentation generation and package dry-run pass.
- Recorded provider fixtures pass without live provider calls.
- Selected live drift checks pass only when separately authorized.
- Release notes state that the public API remains stable and explain internal
  architecture risk.

## Progress rule

Update this file only with direct evidence. A reviewed and merged change can
mark one step complete. A plan, draft pull request, or elapsed date cannot.

## Related sources

- [V2 scope](v2-scope.md)
- [V2 source map](../reference/v2-source-map.md)
- [V2 migration audit](../../guides/v2-migration-audit.md)
- [V1 compatibility policy](../../COMPATIBILITY.md)
- [Provider extension decision](../../guides/provider-extension-decision.md)
- [Closed historical V2 issue 830](https://github.com/agentjido/req_llm/issues/830)
