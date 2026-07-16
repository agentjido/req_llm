# ReqLLM V1 Execution Goal

> Active execution charter — July 16, 2026

[Roadmap index](ROADMAP.md) ·
[V1 roadmap](ROADMAP_V1.md) ·
[Compatibility policy](COMPATIBILITY.md) ·
[V1 master tracker #829](https://github.com/agentjido/req_llm/issues/829)

## Goal

Complete the ReqLLM V1 roadmap one issue at a time while preserving the
behavior that existing applications and third-party providers rely on. Every
issue must leave `main` at least as understandable, maintainable, and well
tested as it was before the work began.

Quality and backward compatibility are the primary constraints. Delivery speed,
architectural novelty, and roadmap completion never justify weakening them.

The desired end state is:

- every active V1 issue is either merged or closed with an evidence-backed
  disposition;
- every merged issue is represented by one focused pull request and one clear
  Conventional Commit in release history;
- `main` passes the complete local quality suite and required GitHub checks;
- public compatibility is protected by characterization, regression, and
  conformance tests; and
- the implementation is simpler, more cohesive, or easier to extend without
  moving agent orchestration into ReqLLM.

## Sources of truth

- [ROADMAP_V1.md](ROADMAP_V1.md) defines the ordered backlog, dependencies,
  compatibility posture, and intended squash titles.
- [Issue #829](https://github.com/agentjido/req_llm/issues/829) records live
  progress, dispositions, dependency changes, and scope decisions.
- Each child issue defines the contract and acceptance criteria for its one
  pull request.
- GitHub Actions and the checked-out `main` branch define the current validation
  baseline.

The roadmap order is the default execution order. Start only the first open,
unblocked issue. Do not implement multiple V1 issues in one branch or pull
request, even when later work appears adjacent.

## The one-issue delivery loop

Repeat this loop until every active V1 roadmap issue has been addressed.

### 1. Establish a clean baseline

1. Fetch and prune the remote repository.
2. Check out `main` and fast-forward it to `origin/main`.
3. Confirm the working tree is clean.
4. Confirm required GitHub checks on `main` are green.
5. Run the smallest local baseline needed to distinguish a pre-existing failure
   from a regression in the upcoming change.

Do not build roadmap work on a red or ambiguous baseline. Investigate a failing
baseline before creating the issue branch and record unrelated infrastructure
failures explicitly.

### 2. Revalidate the issue

Before writing code:

1. Confirm the issue is open, unblocked, and still matches current `main`.
2. Read its dependencies, acceptance criteria, exclusions, and non-breaking
   merge gate.
3. Inspect the relevant implementation, tests, public documentation, types,
   fixtures, telemetry, and provider callbacks.
4. Write down the observable behavior that must remain unchanged.
5. Reduce or clarify scope when the issue no longer fits one reviewable pull
   request.

If current `main` already satisfies the issue, close it with code and test
evidence and update #829. If a safe V1 implementation is not possible, narrow
the issue to an additive or internal change or move it to the V2 tracker. Do not
force a breaking implementation merely to close a ticket.

### 3. Create one focused branch

Create `agent/issue-<number>-<short-description>` from the current
`origin/main`. The branch contains only the selected issue. Preserve unrelated
working-tree changes and do not carry planning-document edits into an
implementation pull request.

### 4. Characterize before changing

Add or identify tests for every relevant legacy behavior before restructuring
it. Prefer black-box assertions at public and provider-extension boundaries over
tests that freeze incidental implementation details.

Characterization is mandatory for changes to request encoding, response
materialization, streaming, errors, timeouts, telemetry, fixtures, provider
selection, or public structs. Golden assertions should be as exact as the
contract requires.

### 5. Implement the smallest complete change

- Solve only the selected issue and its directly required documentation and
  tests.
- Prefer deleting duplication, consolidating existing paths, and naming current
  concepts over introducing parallel abstractions.
- Keep the existing public facade and provider behavior available throughout
  V1.
- Make new strictness, richer results, and provider-specific depth additive or
  explicitly opt-in.
- Do not add agent loops, cross-call retries, approvals, memory, checkpointing,
  or durable orchestration to ReqLLM.
- Do not edit `CHANGELOG.md`; the Conventional Commit is the release-history
  unit.
- Follow the repository rule forbidding comments inside function bodies.

An implementation that increases conceptual surface without removing more
complexity must justify that tradeoff in the pull request.

### 6. Validate locally

Run focused tests continuously, then run the broadest relevant validation before
publishing:

1. `mix format --check-formatted`
2. focused unit, provider, streaming, fixture, or coverage tests for the change
3. the full cached `mix test` suite
4. `mix quality`
5. relevant compatibility or model-coverage Mix tasks when scenario metadata,
   fixtures, support evidence, or provider behavior changes

Docs-only changes still require formatting, compilation, documentation checks
where available, and enough of the test suite to prove links, examples, and
types remain valid. Live provider calls are used only when the issue requires
new live evidence and credentials are intentionally available; normal CI stays
replay-based.

### 7. Publish one ready pull request

Stage only files belonging to the issue. Commit with the roadmap's Conventional
Commit title, push the branch, and open a ready-for-review pull request against
`main`.

The pull request must:

- close exactly one roadmap issue;
- explain the problem, chosen design, user impact, and compatibility analysis;
- list tests and commands run;
- call out request, response, serialization, error, telemetry, fixture, and
  provider-extension effects where relevant; and
- contain no unrelated cleanup.

### 8. Review and harden

Perform a substantive merge-readiness review after publication. Review in this
order:

1. correctness and behavior regressions;
2. missing or weak compatibility coverage;
3. unnecessary architecture or avoidable duplication;
4. merge conflicts and drift from `main`;
5. GitHub checks and unresolved review threads.

Apply `needs_work` whenever a blocker remains and remove `ready_to_merge`.
Address every blocker on the pull-request branch, strengthen tests, rerun local
validation, push the fixes, and review again. Apply `ready_to_merge` and remove
`needs_work` only when the pull request is merge-clean, CI is green, coverage is
appropriate for the risk, and no blocking comment remains.

### 9. Merge and verify

Squash-merge using the issue's Conventional Commit title and delete the remote
branch only after all merge gates pass. Then:

1. fast-forward the local `main` branch;
2. verify the merge commit and issue closure;
3. verify required post-merge checks on `main`;
4. update #829 with the result and any scope decision; and
5. remove stale local branches or worktrees when safe.

Do not start the next issue until the merged change is green on `main`. A
post-merge regression belongs to the current issue's delivery cycle and must be
resolved before roadmap execution continues.

## Backward-compatibility merge gate

Every pull request must explicitly determine which of these contracts it
touches and prove that untouched legacy behavior remains identical:

| Contract | Required V1 evidence |
| --- | --- |
| Public functions | Existing names, arities, accepted inputs, defaults, return tuples, and bang behavior continue to work. |
| Public values | Struct keys and defaults, equality, `Map.from_struct/1`, `Inspect`, and Jason output remain unchanged unless a new value is explicitly opt-in. |
| Requests | Existing provider selection, option precedence, headers, body encoding, retry behavior, and fixture payloads remain exact outside the intended fix. |
| Results | Response content, ordering, usage, warnings, provider metadata, and buffered/streamed parity remain compatible. |
| Streams | Chunk order and meaning, single-consumer behavior, cancellation, terminal delivery, timeout semantics, and resource cleanup remain compatible. |
| Errors | Public error terms and fields plus bang exception modules and messages remain exact unless the issue documents an intentional bug fix. |
| Providers | Current `ReqLLM.Provider` callbacks, defaults, registration, inline model specs, and third-party adapters remain supported. |
| Telemetry | Existing event names, metadata and measurement keys, value types, meanings, units, and redaction behavior remain stable. |
| Evidence | Scenario IDs, fixture names, replay behavior, support-state semantics, and generated artifacts change only when the issue requires it. |
| Platform | Supported Elixir and OTP versions compile and behave consistently; warnings, Dialyzer, and Credo remain clean. |

Intentional correctness fixes must be narrowly tied to documented or typed
behavior, carry a regression test, and avoid collateral request or response
changes. When an issue cannot meet this table, it is a V2 candidate rather than
a V1 merge.

## Quality and simplification standard

A roadmap pull request is successful only when it improves the system rather
than merely relocating complexity. Prefer changes that:

- remove duplicate branching or materialization paths;
- make invalid states harder to represent internally;
- isolate provider-specific behavior without widening the common API;
- replace implicit behavior with inspectable data and precise warnings;
- keep tests scenario-oriented and reusable across surfaces;
- reduce the number of places required to add or repair a provider capability;
- preserve a short, obvious path for the common call; and
- make failure ownership and remediation clear.

Track meaningful before-and-after evidence in the pull request: duplicated code
removed, branches consolidated, fixtures unified, provider-specific cases
isolated, or public behavior newly protected by tests. Raw line-count reduction
is useful context, not a goal by itself.

## Stop conditions

Pause the current issue rather than merge when any of these is true:

- required CI is red or missing;
- the branch does not merge cleanly with current `main`;
- a public compatibility effect is unknown or untested;
- exact fixture, serialization, error, or telemetry behavior changed without an
  accepted issue requirement;
- a third-party provider could silently break;
- the implementation needs more than one coherent rollback boundary;
- a live-provider assertion is essential but cannot be established safely; or
- review identified a correctness blocker that remains unresolved.

Record the blocker in the issue and #829. Resume only when the evidence is
available or the scope has been safely changed.

## Definition of addressed

An issue is addressed in exactly one of these ways:

1. **Merged:** one focused pull request has passed all gates, landed on `main`,
   closed the issue, and passed post-merge CI.
2. **Already satisfied:** current `main` demonstrably meets the acceptance
   criteria and the issue is closed with links to implementation and tests.
3. **Consolidated:** the issue is a true duplicate whose complete scope is
   represented by another V1 issue, with both issues and #829 cross-linked.
4. **Moved out of V1:** compatibility analysis proves that the valuable form of
   the work requires a breaking change; the rationale and V2 destination are
   recorded before closing the V1 issue.
5. **Not planned:** evidence shows the feature adds unjustified complexity or
   violates the ReqLLM/Jido boundary, and the closure documents the alternative.

Closing an issue without one of these evidence-backed outcomes does not count as
roadmap progress.

## Completion criteria

The V1 execution goal is complete when:

- all active child issues in ROADMAP_V1.md and #829 are addressed;
- #829 contains the final disposition and pull request for every child issue;
- no accepted V1 work remains hidden in a combined or follow-up pull request;
- the complete cached test suite, `mix quality`, relevant compatibility tasks,
  and required GitHub checks pass on current `main`;
- compatibility evidence covers every new stable contract;
- V2-only behavior remains opt-in, deprecated, or absent from V1;
- ReqLLM still performs one model interaction per operation and Jido owns agent
  orchestration; and
- a final architecture review confirms that the resulting codebase is more
  cohesive and no harder to extend than the baseline.
