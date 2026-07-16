# ReqLLM 2.0 Roadmap

> Intentional breaking changes — discussion draft, July 16, 2026

[Back to the roadmap index](ROADMAP.md) ·
[V1 roadmap](ROADMAP_V1.md) ·
[Master tracking issue #830](https://github.com/agentjido/req_llm/issues/830)

ReqLLM 2.0 is a controlled contract migration built on V1 bridges, not a port of
the reqllm_next prototype. It acknowledges that the changes below break existing
callers and limits the major release to breaks with clear user or maintenance
return.

## Scope

### 1. Remove deprecated bang streaming APIs

Remove stream_text! and stream_object!, which currently warn and return :ok
instead of a stream.

- **Why it is worth considering:** bang normally communicates exception
  behavior, but these functions do not return a usable stream. Keeping them
  creates a misleading API.
- **V1 bridge:** stream_text/stream_object plus StreamResponse projections.
- **Migration:** replace the bang function with its non-bang counterpart and
  consume the returned StreamResponse.
- **Success measure:** the migration audit finds no bang streaming calls in
  ReqLLM examples or known first-party dependents.

### 2. Make canonical tagged events the default raw stream

Change the primary raw streaming contract from the four-type StreamChunk shape
to canonical lifecycle and output events.

- **Why it is worth considering:** tool calls, reasoning, sources, files,
  warnings, cancellation, and provider metadata need explicit lifecycle
  semantics. Continuing to overload a small chunk struct makes extensions
  ambiguous.
- **V1 bridge:** StreamResponse.events plus explicit text, item, event, and
  legacy-chunk projections.
- **Migration:** select the projection the consumer actually needs; consumers of
  raw streams move to tagged events.
- **Compatibility option:** retain an explicitly named legacy projection if its
  maintenance cost remains small, but do not retain ambiguous .stream semantics.
- **Success measure:** buffering canonical events and making the equivalent
  non-streaming call produce semantically equivalent results.

### 3. Replace the legacy provider extension behavior

Make the stable V2 provider extension contract use explicit planning, semantic
protocol, wire, transport, and response seams.

- **Why it is worth considering:** the monolithic behavior couples request
  intent, provider meaning, HTTP details, streaming, and materialization. The
  coupling increases provider maintenance and parity drift.
- **V1 bridge:** the legacy behavior remains supported through an adapter while
  first-party providers move one surface at a time.
- **Migration:** third-party providers adopt the narrower contracts with a
  focused author guide and conformance suite.
- **Gate:** survey actual third-party provider authors before freezing the V2
  extension SDK.
- **Success measure:** adding a compatible provider surface does not require
  branching through shared execution code.

### 4. Require namespaced provider options

Reject ambiguous legacy flat provider options and require provider-keyed
options.

- **Why it is worth considering:** flat shapes can silently forward, collide,
  or be ignored when callers change models.
- **V1 bridge:** accept both shapes, normalize once, validate foreign keys, and
  warn on legacy or conflicting input.
- **Migration:** move provider-specific keys beneath the relevant provider name;
  keep cross-provider options such as reasoning in the canonical option set.
- **Success measure:** every unknown or foreign provider option produces a
  deterministic error before I/O.

### 5. Make strict final structured-output validation the default

Return an error when the final materialized value violates its declared output
contract unless the caller explicitly selects a permissive policy.

- **Why it is worth considering:** a successful structured response that violates
  its schema is silent wrongness and pushes provider-dependent validation into
  every application.
- **V1 bridge:** explicit strict, warning, and permissive/coercion policies;
  structured warnings; final-value validation; bounded opt-in repair.
- **Migration:** fix invalid schemas or explicitly request permissive behavior
  where partial tolerance is intentional.
- **Success measure:** no successful strict response violates its declared final
  contract.

## Bridge matrix

| V2 break | Required V1 bridge | Minimum evidence before acceptance |
| --- | --- | --- |
| Remove bang streaming APIs | Non-bang APIs, projections, warnings, migration audit | Two minor releases and no first-party uses |
| Canonical events become raw default | Event stream and explicit legacy projection | Stream/non-stream parity across anchor providers |
| Replace provider behavior | Legacy adapter and first-party vertical slices | Ecosystem survey plus third-party conformance proof |
| Require namespaced provider options | Dual-form normalization and warnings | Static audit and usage telemetry where available |
| Strict validation becomes default | Explicit policies and structured warnings | Provider matrix for object/array/choice/JSON contracts |

## Entry gates

Every gate is required before a V2 release candidate:

- each breaking item has shipped as an additive V1 bridge for at least two minor
  releases;
- public compatibility scenarios cover old and new behavior before default
  changes;
- each mechanical change has a migration guide and, where useful, a static Mix
  task check;
- third-party provider authors have been surveyed before the extension contract
  freezes;
- the release candidate passes the same model/surface/scenario evidence as the
  latest V1 release;
- the supported Elixir/OTP window comes from ecosystem need, not the prototype;
  and
- each break can be independently reverted during the release-candidate cycle.

## Release sequencing

1. Freeze the list of accepted breaks; additions after the first release
   candidate wait for a later major.
2. Publish a V1 migration release with all bridges, warnings, and audit tooling.
3. Measure adoption for at least two V1 minor releases.
4. Publish the V2 migration guide before the first release candidate.
5. Land one breaking change per pull request so release history identifies the
   exact contract change and rollback point.
6. Run compatibility evidence after every breaking pull request.
7. Release V2 only when all accepted changes and docs pass the entry gates.

The V2 tracker may group the release, but implementation issues and pull requests
must not combine multiple breaking changes.

## Explicit non-goals

- Do not move agent loops, approvals, memory, checkpointing, retries across model
  calls, or durability into ReqLLM; those remain Jido concerns.
- Do not remove tuple or plain-map model inputs solely for API purity.
- Do not change Response.model to an LLMDB.Model when an additive resolved
  profile field is sufficient.
- Do not remove generate_object or stream_object; keep them as convenience
  wrappers over the output contract.
- Do not copy the reqllm_next module tree or require its development workflow as
  ReqLLM runtime architecture.
- Do not raise the Elixir requirement solely to match the prototype.
- Do not bundle unrelated naming cleanups into the major release.
- Do not treat a major version as permission for an unmeasured rewrite.

## Decisions required before V2 planning

1. Is the provider behavior a promised third-party extension API?
2. Does the legacy StreamChunk projection remain for all of V2?
3. Which structured-output policy should V1 use before strict becomes the V2
   default?
4. Is the deprecation window two minor releases, or six months plus two minors?
5. Which Elixir and OTP versions must V2 support?

Until the V1 bridges provide evidence for these decisions, V2 remains a bounded
candidate roadmap rather than a release commitment.
