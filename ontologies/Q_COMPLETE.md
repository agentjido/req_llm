# Q (SHACL Guards) Implementation Complete ✅

## Summary

Successfully implemented the **Q (SHACL Guards)** phase of the ACHI pipeline for req_llm. Semantic validation constraints are now enforced at runtime and in CI, ensuring data integrity and compliance with the domain ontology.

## Implementation Status

### ✅ Completed Artifacts

1. **SHACL Shapes File** (`ontologies/reqllm.shapes.ttl`)
   - 11 NodeShapes covering all core classes
   - 50+ property constraints with cardinality, datatype, and value restrictions
   - Enumeration constraints for Role, ChunkType, FinishReason
   - Range constraints (temperature 0.0-2.0, non-negative tokens)
   - Pattern constraints (ImagePart mediaType must start with "image/")

2. **Elixir Runtime Validator** (`lib/req_llm/ontology/validator.ex`)
   - `validate_response/1` - Full response validation
   - `validate_context/1` - Context and message list validation
   - `validate_message/1` - Message with role and parts validation
   - `validate_part/1` - Type-specific ContentPart validation
   - `validate_usage/1` - Usage metrics validation
   - Handles both atom and string type representations
   - Returns `:ok` or `{:error, [error_messages]}`

3. **Validation Test Suite** (`test/ontology_validation_test.exs`)
   - 34 comprehensive tests
   - All ContentPart variants tested
   - Valid and invalid cases for each constraint
   - Round-trip validation with Emitter integration
   - **All 34 tests passing** ✅

4. **Apache Jena Validation Script** (`script/validate_shacl.sh`)
   - Auto-downloads Apache Jena 5.2.0 if missing
   - Validates RDF data against SHACL shapes
   - Used for full W3C SHACL compliance checking
   - Integrated into CI pipeline

5. **Updated CI Pipeline** (`.github/workflows/ontology.yml`)
   - Elixir + Java setup for SHACL validation
   - Runs round-trip tests
   - Runs validation tests (34 tests)
   - Runs Apache Jena SHACL validator
   - Enforces Σ receipt hash

6. **Documentation** (`ontologies/SHACL_CONSTRAINTS.md`)
   - Comprehensive constraint descriptions
   - Examples of valid/invalid data
   - Common validation errors and fixes
   - Usage instructions for both runtime and CI validation

## SHACL Constraints Summary

### Core Constraints Implemented

| Shape | Required Properties | Optional Properties | Special Constraints |
|-------|-------------------|-------------------|-------------------|
| **MessageShape** | role (1), hasPart (≥1) | position | role ∈ {system, user, assistant, tool} |
| **ResponseShape** | hasContext (1), hasMessageOut (1), finishReason (1) | id, hasUsage | finishReason ∈ {Stop, Length, ToolCalls, ContentFilter, Error} |
| **ContextShape** | hasMessage (≥1) | externalId | - |
| **UsageShape** | - | inputTokens, outputTokens, etc. | All tokens/costs ≥ 0 |
| **TextPartShape** | text (1) | - | text.length > 0 |
| **ImageURLPartShape** | url (1) | - | url is IRI |
| **ImagePartShape** | mediaType (1), payload (1) | - | mediaType starts with "image/" |
| **ToolCallPartShape** | toolName (1), argumentsJson (1) | - | toolName.length > 0 |
| **ToolResultPartShape** | toolCallId (1), resultJson (1) | - | - |
| **StreamChunkShape** | chunkType (1) | chunkText, chunkMeta | chunkType ∈ {content, thinking, tool_call, meta} |
| **ToolShape** | name (1), description (1) | parameterSchema | name.length > 0 |
| **ModelShape** | provider (1), modelName (1) | temperature, maxTokens | temperature ∈ [0.0, 2.0], maxTokens ≥ 1 |

## Test Results

### Validation Tests

```
Running ExUnit with seed: 846350, max_cases: 20

..................................
Finished in 0.07 seconds (0.07s async, 0.00s sync)
34 tests, 0 failures ✅
```

### Test Coverage

- ✅ `validate_response/1` - 4 tests
- ✅ `validate_context/1` - 3 tests
- ✅ `validate_message/1` - 5 tests
- ✅ `validate_part/1` (TextPart) - 3 tests
- ✅ `validate_part/1` (ImageURLPart) - 2 tests
- ✅ `validate_part/1` (ImagePart) - 4 tests
- ✅ `validate_part/1` (ToolCallPart) - 3 tests
- ✅ `validate_part/1` (ToolResultPart) - 3 tests
- ✅ `validate_usage/1` - 4 tests
- ✅ Integration with Emitter - 2 tests
- ✅ Round-trip validation - 1 test

### Round-Trip Tests (from ggen phase)

```
Running ExUnit with seed: 883855, max_cases: 20

......
Finished in 0.04 seconds (0.04s async, 0.00s sync)
6 tests, 0 failures ✅
```

## Usage Examples

### 1. Runtime Validation

```elixir
alias ReqLLM.Ontology.Validator

# Validate a response
response = %{
  id: "resp_123",
  finish_reason: :stop,
  context: %{
    messages: [
      %{role: :user, parts: [%{type: :text, text: "Hello"}]}
    ]
  },
  message: %{
    role: :assistant,
    parts: [%{type: :text, text: "Hi there!"}]
  },
  usage: %{input_tokens: 10, output_tokens: 5}
}

case Validator.validate_response(response) do
  :ok ->
    IO.puts("✅ Response is valid")
  {:error, errors} ->
    IO.puts("❌ Validation failed:")
    Enum.each(errors, &IO.puts("  - #{&1}"))
end
```

### 2. Validation Before Emission

```elixir
alias ReqLLM.Ontology.{Validator, Emitter}

# Validate before emitting to JSON-LD
response = build_response()

with :ok <- Validator.validate_response(response) do
  jsonld = Emitter.emit_response(response)
  # Safe to use jsonld
else
  {:error, errors} ->
    # Handle validation errors
    {:error, {:invalid_response, errors}}
end
```

### 3. CI Validation

```bash
# Run validation tests
mix test test/ontology_validation_test.exs

# Run Apache Jena SHACL validator
bash script/validate_shacl.sh \
  ontologies/reqllm.shapes.ttl \
  ontologies/reqllm.sigma_observed.ttl
```

## File Structure

```
/Users/speed/sean/req_llm/
├── lib/req_llm/ontology/
│   ├── context.ex          # JSON-LD context loader
│   ├── emitter.ex          # Struct → JSON-LD emitters
│   ├── parser.ex           # JSON-LD → map parsers
│   └── validator.ex        # SHACL-based runtime validator ✅ NEW
├── test/
│   ├── ontology_roundtrip_test.exs   # Round-trip tests (6 tests)
│   └── ontology_validation_test.exs  # Validation tests (34 tests) ✅ NEW
├── script/
│   ├── check_sigma_hash.exs          # CI receipt guard
│   └── validate_shacl.sh             # Apache Jena SHACL validator ✅ NEW
├── .github/workflows/
│   └── ontology.yml                  # CI pipeline (updated) ✅ UPDATED
└── ontologies/
    ├── reqllm.sigma_observed.ttl     # Σ (normalized ontology)
    ├── reqllm.sigma_normalized.ttl   # μ-alignment
    ├── reqllm.version.ttl            # Receipt (hash: 2aeb94264b64)
    ├── reqllm.context.jsonld         # JSON-LD context
    ├── reqllm.mapping.yaml           # Repo mapping
    ├── reqllm.shapes.ttl             # SHACL constraints ✅ NEW
    ├── clnrm_analysis.md             # clnrm analysis
    ├── GGEN_V0_COMPLETE.md           # ggen completion
    ├── CLNRM_COMPLETE.md             # clnrm completion
    ├── SHACL_CONSTRAINTS.md          # Constraint docs ✅ NEW
    └── Q_COMPLETE.md                 # This document ✅ NEW
```

## Design Decisions

### Why Both Elixir Validator and Apache Jena?

**Elixir Runtime Validator:**
- Fast, lightweight validation for development and production
- Integrated into Elixir application flow
- Immediate feedback without external dependencies
- Type-safe, pattern-matched validation
- Handles both structs and maps

**Apache Jena SHACL Validator:**
- Full W3C SHACL compliance
- Validates against formal ontology specification
- Used in CI for authoritative validation
- Ensures RDF/Turtle correctness
- Industry-standard validation tool

### Why SHACL Instead of ExCheck/StreamData?

1. **Semantic validation**: SHACL validates against domain ontology, not just structure
2. **Standard compliance**: W3C SHACL is an industry standard for RDF validation
3. **Ontology-driven**: Constraints are first-class citizens in the knowledge graph
4. **Tooling ecosystem**: Apache Jena, TopBraid, etc. support SHACL
5. **Documentation as code**: SHACL shapes serve as formal specification

### Type Detection Strategy

The validator handles multiple type representations:
- Atom types: `:text`, `:image_url`, `:tool_call`
- String types: `"text"`, `"image_url"`, `"tool_call"`
- RDF types: `"TextPart"`, `"ImageURLPart"`, `"ToolCallPart"`
- Structural inference: Detects type from field presence

This allows validation of:
- Elixir structs/maps (before emission)
- JSON-LD documents (after emission)
- Mixed representations (during development)

## Impact on Development Workflow

### Before Q Phase

```elixir
# No validation - errors discovered at runtime or in logs
response = %{id: "resp_123", finish_reason: :unknown_reason}
jsonld = Emitter.emit_response(response)  # Emits invalid data
```

### After Q Phase

```elixir
# Validation catches errors early
response = %{id: "resp_123", finish_reason: :unknown_reason}

case Validator.validate_response(response) do
  :ok ->
    Emitter.emit_response(response)
  {:error, errors} ->
    # Error: "Response finishReason must be one of: stop, length, tool_calls, content_filter, error"
    {:error, {:validation_failed, errors}}
end
```

## Benefits

1. **Early Error Detection**: Invalid data caught before emission
2. **Type Safety**: Ensures conformance to ontology schema
3. **Better Error Messages**: Specific, actionable validation errors
4. **CI Enforcement**: Invalid ontology changes blocked in CI
5. **Documentation**: SHACL shapes serve as formal specification
6. **Debugging**: Validation errors pinpoint exact issues
7. **Compliance**: W3C SHACL standard for interoperability

## Verification Checklist

- [✅] Author SHACL shapes file (`reqllm.shapes.ttl`)
- [✅] Implement Elixir runtime validator
- [✅] Create validation test suite (34 tests passing)
- [✅] Add Apache Jena validation script
- [✅] Integrate into CI pipeline
- [✅] Document constraints (`SHACL_CONSTRAINTS.md`)
- [✅] Create completion documentation (`Q_COMPLETE.md`)
- [✅] All tests passing (6 round-trip + 34 validation = 40 total)

## Next Steps

### Phase: KNHK (Knowledge Hooks)

**Goal**: Ontology-aware runtime with semantic telemetry and audit trails

**Tasks**:

1. **Runtime Decorators**:
   - Auto-tag function calls with ontology metadata
   - Inject RDF triples into telemetry spans
   - Track ontology coverage metrics

2. **Telemetry Integration**:
   - OpenTelemetry spans with RDF metadata
   - Usage tracking (inputTokens, outputTokens, costs)
   - FinishReason distribution metrics
   - ContentPart type distribution

3. **Audit Trail Persistence**:
   - Log Usage metrics to database/file
   - Track FinishReason frequency (error monitoring)
   - StreamChunk ledger for debugging and compliance
   - Context replay for issue reproduction

4. **Documentation Auto-Generation**:
   - Generate ExDoc from Σ ontology
   - Create API docs from SHACL constraints
   - Build interactive schema explorer
   - Auto-update CHANGELOG from ontology diffs

5. **Hook Examples**:
   ```elixir
   # Pre-call hook
   @ontology_tracked response: req:Response
   def generate_text(context, opts) do
     with :ok <- Validator.validate_context(context) do
       # ... call LLM
     end
   end

   # Post-call hook (telemetry)
   :telemetry.execute([:req_llm, :response, :complete], %{
     input_tokens: response.usage.input_tokens,
     finish_reason: response.finish_reason,
     ontology_type: "req:Response"
   })
   ```

### Phase: gitvan (Deterministic Versioning)

**Goal**: Semantic versioning based on ontology changes

**Tasks**:
- Detect breaking changes in Σ (removed properties, tightened constraints)
- Auto-bump version based on ontology diffs
- Generate migration guides from Σ changes
- Semantic changelog from ontology history

## Evidence & Traceability

All implementation aligned with:
- **SHACL Shapes**: `ontologies/reqllm.shapes.ttl`
- **Σ (normalized)**: `ontologies/reqllm.sigma_observed.ttl`
- **Validator**: `lib/req_llm/ontology/validator.ex`
- **Tests**: `test/ontology_validation_test.exs` (34/34 passing)
- **CI**: `.github/workflows/ontology.yml`
- **Receipt**: `ontologies/reqllm.version.ttl` (hash: 2aeb94264b64)

---

**Status**: ✅ **PRODUCTION READY (Q Phase)**

**Tests**: 40 total (6 round-trip + 34 validation)

**SHACL Shapes**: 11 NodeShapes, 50+ constraints

**Date**: 2025-11-10

**Next Phase**: KNHK (knowledge hooks) → gitvan (versioning)

**Pipeline Progress**: unrdf ✅ → ggen ✅ → clnrm ✅ → Q ✅ → **KNHK (next)** → gitvan
