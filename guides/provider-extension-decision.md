# Provider Extension Manifest Decision

> Status: accepted for ReqLLM 1.x, July 17, 2026

## Decision

ReqLLM 1.x will keep provider extensions as plain Elixir modules and data. It
will not add a provider extension manifest, a second provider DSL, compile-time
extension aggregation, or a new runtime dependency.

The supported extension contract remains:

- `ReqLLM.Provider` for provider callbacks and provider identity;
- `ReqLLM.Provider.Defaults` for the OpenAI-compatible baseline;
- `ReqLLM.Providers.register/1` and `:custom_providers` for runtime and
  application-config registration;
- explicit model specifications or LLMDB metadata for model facts; and
- provider contract tests, compatibility scenarios, and fixtures for evidence.

This is a V1 architecture decision, not a permanent rejection of declarative
provider metadata. A future proposal must demonstrate a concrete limit of the
current contract before adding another authoring or runtime layer.

## Context

The separate `reqllm_next` prototype explored a compiled manifest made from
provider declarations, execution families, matching rules, allowed seams,
compile-time verification, and a runtime registry. Spark supplied its authoring
DSL while the runtime consumed normalized data.

That design addresses a broader problem than ReqLLM 1.x currently has: selecting
an entire semantic, wire, transport, and adapter stack from declarative rules.
Adopting it in V1 would introduce a parallel extension contract while the public
`ReqLLM.Provider` behavior must remain supported. It would also turn runtime
registration into a special case and add migration work without removing the
existing path.

The V1 roadmap therefore required evidence from provider conformance work,
measured OpenAI seam extraction, existing extension users, and the prototype
before deciding whether a manifest had earned that cost.

## Current V1 extension surface

| Need | Existing contract |
| --- | --- |
| Provider identity and defaults | `use ReqLLM.Provider`, `provider_id/0`, `default_base_url/0`, and `default_env_key/0` |
| OpenAI-compatible behavior | `ReqLLM.Provider.Defaults` with selective callback overrides |
| Provider-only options | `@provider_schema` and namespaced `provider_options` |
| Local registration | `config :req_llm, :custom_providers, [...]` or `ReqLLM.Providers.register/1` |
| Local or newly released models | Explicit maps or `%LLMDB.Model{}` values without catalog membership |
| Catalog and tooling integration | LLMDB metadata or a local model patch |
| Provider-specific wire behavior | Provider callbacks and focused provider-owned modules |
| Compatibility proof | Provider extension contracts, scenarios, request fixtures, and replay tests |

Issue [#832](https://github.com/agentjido/req_llm/issues/832) locked
these extension contracts with tests. Issue
[#856](https://github.com/agentjido/req_llm/issues/856) then extracted the
OpenAI Chat Completions request-envelope seam only after duplicate buffered and
streaming construction was measured. That work did not require a provider
manifest or a new public abstraction.

## Ecosystem evidence

The extension reports reviewed for this decision identify narrower problems:

- [#255](https://github.com/agentjido/req_llm/issues/255) requested reliable
  application-local registration and model use. Config registration and explicit
  model specifications now cover that path.
- [#283](https://github.com/agentjido/req_llm/issues/283) exposed documentation
  and discovery gaps for custom providers, not a missing manifest runtime.
- [#620](https://github.com/agentjido/req_llm/issues/620) found a missing LLMDB
  capability for a custom reranker. The fix belonged in model metadata rather
  than provider registration.

Public application code also exercises the runtime contract directly:

- [Pi installs an adapter with `ReqLLM.Providers.register/1`](https://github.com/elixir-vibe/pi-elixir/blob/6e494cea5b4f5d4f9452e24d28bf1c5ac8089245/packages/bridge/lib/pi/req_llm.ex).
- [Condukt registers an application-owned Ollama provider at startup](https://github.com/tuist/condukt/blob/cd0b4a44c636dfc3cf6edc2155d5487cb5663689/lib/condukt/application.ex).
- [Loomkin builds providers for runtime-configured OpenAI-compatible endpoints](https://github.com/pass-agent/loomkin/blob/f769ae73adeed9bed4588934c09a6e99c87233c3/loomkin-server/lib/loomkin/providers/openai_compatible_provider.ex).

These examples favor a stable runtime module contract. The Loomkin example also
shows pressure for carefully chosen reusable OpenAI-compatible seams. It does
not show that endpoint configuration should become a compile-time manifest.

## Alternatives considered

### Adopt the `reqllm_next` manifest in V1

Rejected. It would add provider, family, rule, criteria, seam, verification, and
registry concepts beside the existing behavior. V1 would retain both systems,
so the manifest would add indirection without paying for itself through removal.
Compile-time aggregation would also work against current dynamic registration
use cases.

### Add a private experimental manifest

Rejected for now. No current implementation is blocked on a declaration that
plain module functions or data cannot express. A private duplicate registry
would still require synchronization, tests, and an exit plan while providing no
user-visible improvement.

### Keep plain modules and extract measured seams

Accepted. It preserves the V1 extension contract, supports runtime applications,
keeps provider facts close to provider code, and allows narrow internal helpers
when tests prove real duplication. The cost is that validation and discovery
remain distributed across behavior checks, model metadata, registration, and
compatibility evidence.

## Reconsideration criteria

A manifest proposal can be reconsidered for V2 or a later additive experiment
only when evidence demonstrates at least one of these conditions:

1. multiple independent provider implementations must repeat the same routing
   facts in provider modules, shared planning code, and model metadata;
2. adding a provider repeatedly requires central runtime branches that cannot be
   moved into a provider-owned module;
3. invalid provider compositions cannot be detected before network I/O through
   the behavior, request plan, model metadata, or registration validation;
4. runtime registration cannot deterministically express a required provider or
   execution-family relationship; or
5. third-party provider authors identify the same concrete declaration or
   discoverability gap after the current guide and contract are applied.

Any new experiment should begin with plain validated data, adapt the existing
`ReqLLM.Provider` contract, remain optional, and define measurable removal
criteria. A Spark dependency, public DSL, or compile-time code generation must
justify itself separately. V2 should adopt a manifest only if it materially
reduces provider maintenance and offers a mechanical migration.

## Consequences

- ReqLLM 1.x gains no new provider-extension API or dependency from this
  decision.
- Existing providers, custom registration, inline models, request shapes, and
  callback behavior remain unchanged.
- Provider work should keep extracting only seams backed by measured
  duplication or branching.
- General middleware remains deferred, and agent orchestration remains in Jido.
- The manifest question is closed for V1 unless new evidence satisfies the
  reconsideration criteria above.
