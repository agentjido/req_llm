---
title: ReqLLM V2 source map
status: current
last-reviewed: 2026-11-15
---

# ReqLLM V2 source map

## Purpose

Show which sources define current behavior, intended V2 changes, and useful
prototype ideas. This page prevents a future worker from treating an experiment
as current ReqLLM authority.

## Authority order

1. Current ReqLLM code and tests define implemented behavior.
2. `COMPATIBILITY.md` defines protected V1 behavior.
3. Accepted repository decisions and the current V2 scope define intended
   behavior.
4. `priv/deprecations.json` records deprecations and historical migration
   candidates. It does not override the current stable-API V2 decision.
5. GitHub issue 830 records a superseded V2 breaking scope.
6. `reqllm_next` supplies ideas only.

## Current ReqLLM sources

| Source | What it owns | V2 use |
| --- | --- | --- |
| [`COMPATIBILITY.md`](../../COMPATIBILITY.md) | Stable V1 public, value, streaming, provider, telemetry, and host contracts | Defines what every additive bridge must preserve. |
| [`guides/v2-migration-audit.md`](../../guides/v2-migration-audit.md) | User migration guidance and audit limits | Defines the current mechanical migration path. |
| [`priv/deprecations.json`](../../priv/deprecations.json) | Active deprecations and historical V2 migration records | V2-01 must reconcile its old approval labels with the current stable-API scope. No record authorizes removal by itself. |
| [`guides/provider-extension-decision.md`](../../guides/provider-extension-decision.md) | V1 provider contract and reconsideration criteria | Blocks a new provider system without measured evidence. |
| `ReqLLM.RequestPlan` and `ReqLLM.Runtime` | Current planning and execution path | They are the base for evolution, not code to replace. |
| Contract tests and recorded fixtures | Protected behavior and provider evidence | They are release and migration gates. |

## GitHub issue 830

[Issue 830](https://github.com/agentjido/req_llm/issues/830) was closed on
2026-10-12. It proposed five bounded V2 changes:

1. Remove approved deprecated bang streaming functions.
2. Make canonical tagged events the default raw stream.
3. Replace the legacy provider behavior after a V1 bridge and ecosystem survey.
4. Require namespaced provider options.
5. Make strict final structured-output validation the default.

It also rejected a rewrite, a direct `reqllm_next` port, removal of tuple and
plain-map inputs, removal of object convenience functions, and an Elixir
version increase based only on the experiment.

The current [V2 scope](../plans/v2-scope.md) supersedes that breaking scope.
It does not remove the bang functions, replace raw chunks, replace the provider
behavior, reject flat provider options, or change the validation default.

The issue also proposed opaque Context storage. The current roadmap excludes
that change.

The repository documents now hold the durable direction, scope, and roadmap.
The issue remains useful as historical discussion.

## `reqllm_next` review

The reviewed repository is
[`mikehostetler/reqllm_next`](https://github.com/mikehostetler/reqllm_next). Its
description marks it as an experiment. The reviewed branch was `main`, last
pushed on 2026-04-03.

| Prototype idea | Disposition | ReqLLM application |
| --- | --- | --- |
| `ModelProfile -> ExecutionMode -> ExecutionPlan` | Adapt | Keep current `RequestPlan`. Add missing descriptive operation data and an internal resolved execution value. |
| One deterministic execution stack | Adopt | Select provider, protocol, wire format, transport, and response builder before execution. |
| Provider and protocol family slices | Adopt in small parts | Move measured provider differences into owned modules. Do not port the directory tree. |
| Canonical output items | Adapt internally | A richer internal reduction contract can remove duplicate logic, but it must project without loss to current response, chunk, and event contracts. |
| Fixture replay and scenario checks | Adopt | Use current fixtures and contract suites. Add live checks only for selected drift risks. |
| Compiled extension manifest and Spark DSL | Defer | Reconsider only when the accepted V1 criteria show repeated central branches or invalid combinations. |
| Only string and `%LLMDB.Model{}` inputs | Reject | Keep current tuple and plain-map support. Normalize internally. |
| Defer Azure, Vertex, and Bedrock | Reject | ReqLLM already supports these platforms. V2 must preserve that functionality. |
| New Spec Led and Beadwork workflow | Do not import | Keep V2 architecture work separate from repository workflow changes. |
| Elixir `~> 1.19` target | Do not import | Select language support from ReqLLM ecosystem needs. |

## Evidence limits

This review used the prototype documentation and selected architecture
decisions. It did not treat prototype tests as proof for current ReqLLM. No
prototype code was copied.
