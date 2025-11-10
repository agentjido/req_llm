# ReqLLM Ontology (Σ) - ACHI Pipeline Artifacts

This directory contains the ontology artifacts for the req_llm repository, following the ACHI (Architecture, Code, History, Infrastructure) methodology.

## Overview

The ReqLLM ontology formalizes the canonical data model for provider-agnostic LLM interactions, including:

- **Core entities**: Model, Context, Message, ContentPart, Tool, Response, StreamResponse, Usage
- **Streaming constructs**: StreamChunk with typed events (content, thinking, tool_call, meta)
- **Enumerations**: Role, ChunkType, FinishReason

## Files

### Σ° (Observed Ontology)
- **`reqllm.sigma_observed.ttl`**: Complete RDF ontology extracted from the repository's canonical data model
  - 11 core classes (Model, Provider, Context, Message, etc.)
  - 7 ContentPart variants (TextPart, ImagePart, ToolCallPart, etc.)
  - 30+ properties mapping domain/range relationships
  - 3 enumeration types with named individuals

### Σ (Normalized Ontology)
- **`reqllm.sigma_normalized.ttl`**: Minimal alignment layer to μ-domain-core
  - Only `rdfs:subClassOf` and `rdfs:subPropertyOf` assertions
  - Maps req: classes to ex: upper ontology (Organization, Asset, Document, Event, Metric, Service)
  - Enables cross-repo semantic queries without modifying Σ°

### Version Receipt
- **`reqllm.version.ttl`**: Pinned version for deterministic CI/CD
  - Hash: `84461b2188fb`
  - Version: Σ.reqllm.v0
  - Timestamp: 2025-11-09T00:00:00Z

### JSON-LD Context
- **`reqllm.context.jsonld`**: Vocabulary mapping for JSON-LD serialization
  - Enables seamless RDF ↔ JSON transformation
  - Pre-defined @vocab: https://schema.reqllm.dev#
  - Type coercions for xsd:integer, xsd:decimal, @id

### Repo Mapping
- **`reqllm.mapping.yaml`**: Concrete Elixir module/field bindings
  - Maps ontology classes → ReqLLM.* modules
  - Maps properties → struct fields
  - Documents ContentPart type discrimination
  - Notes for implementers on unions and embedded maps

### SPARQL Queries
- **`queries/messages_in_context.rq`**: Validation query ensuring all contexts have ≥1 message

## ACHI Pipeline Status

✅ **unrdf** (extract): Σ° extracted from canonical data model
✅ **ggen** (generate): JSON-LD context + mapping files ready
⏳ **clnrm** (normalize): Awaiting implementation (next phase)
⏳ **Q (SHACL)**: Guards for invariants (next phase)
⏳ **Gitvan**: Receipt versioning (next phase)
⏳ **KNHK**: Runtime integration hooks (next phase)

## Current Phase: ggen v0

**You are here**: Ready to implement ggen adapters.

### Next Steps

1. **Emitters**: Implement functions to serialize Elixir structs → JSON-LD
   - `emit_response/1` - ReqLLM.Response → JSON-LD
   - `emit_context/1` - ReqLLM.Context → JSON-LD
   - `emit_message/1` - ReqLLM.Message → JSON-LD
   - `emit_stream_chunk/1` - ReqLLM.StreamChunk → JSON-LD
   - `emit_usage/1` - Usage map → JSON-LD

2. **Parsers** (optional): JSON-LD → Elixir structs
   - `parse_response/1`
   - `parse_context/1`
   - etc.

3. **Round-trip tests**: Ensure struct → JSON-LD → struct equality

4. **CI Integration**:
   - Validate emitted graphs against Σ° (no SHACL yet)
   - Check `Σ_HASH` matches `reqllm.version.ttl`
   - Fail builds on ontology drift

## Evidence Sources

All ontology classes and properties are derived from:

1. **Hexdocs**: https://preview.hex.pm/preview/req_llm/1.0.0/show/guides/data-structures.md
2. **GitHub**: https://github.com/agentjido/req_llm/
3. **Source files**:
   - `lib/req_llm/response.ex` (Response, StreamResponse, Usage)
   - `lib/req_llm/message.ex` (Message, ContentPart)
   - `lib/req_llm/stream_chunk.ex` (StreamChunk, ChunkType)
   - `lib/req_llm/model.ex` (Model, Provider)

## Future Phases

### clnrm (Normalization)
- Dead property removal
- Synonym merging (e.g., `hasContextSR` ≡ `hasContext`)
- Prefix hygiene
- Deterministic serialization

### Q (SHACL Guards)
High-value invariants to encode:
- `Message` requires exactly 1 `role` and ≥1 `hasPart`
- `TextPart` requires `text`; `ImageURLPart` requires `url`
- `Response` requires `hasContext`; optional `hasMessageOut`
- `finishReason` ∈ {Stop, Length, ToolCalls, ContentFilter, Error}
- `Usage` token fields are non-negative integers
- `StreamChunk` requires `chunkType` and type-specific fields

### Gitvan (Versioning)
- Deterministic ontology diffs
- Receipt chains across commits
- Semantic change detection

### KNHK (Knowledge Hooks)
- Runtime decorators for ontology tagging
- Telemetry integration
- Audit trail persistence (Usage, FinishReason)
- StreamChunk ledger for compliance

## Usage

### Loading the Ontology

```elixir
# Load JSON-LD context
{:ok, context} = File.read!("ontologies/reqllm.context.jsonld") |> Jason.decode()

# Emit a response as JSON-LD
response = %ReqLLM.Response{...}
jsonld = ReqLLM.Ontology.emit_response(response, context)
```

### Validating with SPARQL

```bash
# Using a SPARQL processor (e.g., Apache Jena)
sparql --data ontologies/reqllm.sigma_observed.ttl \
       --data my_responses.ttl \
       --query ontologies/queries/messages_in_context.rq
```

## Hash Verification

Current ontology hash: **84461b2188fb**

To verify:
```bash
cat ontologies/reqllm.sigma_observed.ttl \
    ontologies/reqllm.sigma_normalized.ttl \
  | sha256sum | head -c 12
```

Expected: `84461b2188fb`

## License

Same as req_llm parent repository.

## Contact

For questions about the ACHI methodology or ontology design, refer to:
- ACHI Documentation (internal)
- μ-domain-core specification
- Σ Architect: Knowledge Geometry team
