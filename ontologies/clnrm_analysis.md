# clnrm Analysis: Σ° Normalization

## Redundancies Identified

### 1. Duplicate Properties (Synonyms)

#### Issue: hasContext duplication
- **Lines 91, 98**: `req:hasContext` and `req:hasContextSR`
- **Problem**: Same semantic meaning, different domains (Response vs StreamResponse)
- **Solution**: Merge into single property with multiple domains

```turtle
# BEFORE (lines 91, 98):
req:hasContext   a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Context .
req:hasContextSR a rdf:Property ; rdfs:domain req:StreamResponse ; rdfs:range req:Context .

# AFTER (normalized):
req:hasContext   a rdf:Property ; rdfs:range req:Context .
# Multiple domains implied by usage on both Response and StreamResponse
```

#### Issue: hasUsage duplication
- **Lines 93, 99**: `req:hasUsage` and `req:hasUsageSR`
- **Problem**: Same semantic meaning, different domains
- **Solution**: Merge into single property

```turtle
# BEFORE:
req:hasUsage   a rdf:Property ; rdfs:domain req:Response ; rdfs:range req:Usage .
req:hasUsageSR a rdf:Property ; rdfs:domain req:StreamResponse ; rdfs:range req:Usage .

# AFTER:
req:hasUsage   a rdf:Property ; rdfs:range req:Usage .
```

### 2. Property Naming Inconsistencies

#### Issue: toolNameProp vs toolName
- **Line 73**: `req:toolName` (for ToolCallPart)
- **Line 80**: `req:toolNameProp` (for Tool)
- **Problem**: Confusing names; both represent "name" concept
- **Solution**: Rename `req:toolNameProp` to `req:name`

```turtle
# BEFORE:
req:toolName     a rdf:Property ; rdfs:domain req:ToolCallPart ; rdfs:range xsd:string .
req:toolNameProp a rdf:Property ; rdfs:domain req:Tool ; rdfs:range xsd:string .

# AFTER:
req:toolName a rdf:Property ; rdfs:domain req:ToolCallPart ; rdfs:range xsd:string .
req:name     a rdf:Property ; rdfs:domain req:Tool ; rdfs:range xsd:string .
```

### 3. Response vs StreamResponse Classes

#### Analysis
- **req:Response**: Final response with message, context, usage
- **req:StreamResponse**: Streaming response handle

**Decision**: Keep both classes - they represent different interaction patterns:
- `Response` = complete, materialized result
- `StreamResponse` = incremental, lazy stream handle

No merge needed, but properties should be unified (see #1 above).

## Changes Summary

### Properties to Remove
- ❌ `req:hasContextSR` → merged into `req:hasContext`
- ❌ `req:hasUsageSR` → merged into `req:hasUsage`

### Properties to Rename
- 🔄 `req:toolNameProp` → `req:name`

### Properties to Update (domains)
- ✅ `req:hasContext`: Remove explicit domain, allow usage on both Response and StreamResponse
- ✅ `req:hasUsage`: Remove explicit domain, allow usage on both Response and StreamResponse

## JSON-LD Context Updates

### Current context.jsonld issues
```json
"hasContextSR":{ "@id":"hasContextSR", "@type":"@id" },
"hasUsageSR":  { "@id":"hasUsageSR",   "@type":"@id" },
```

### After clnrm
```json
// Remove SR variants, use unified properties
// Emitters/parsers already handle both Response and StreamResponse via hasContext/hasUsage
```

## Impact on Emitters/Parsers

### Minimal Changes Required

**Emitter** (`lib/req_llm/ontology/emitter.ex`):
- Already uses `hasContext` and `hasUsage` for both Response and StreamResponse
- No code changes needed ✅

**Parser** (`lib/req_llm/ontology/parser.ex`):
- Already handles unified properties
- No code changes needed ✅

**JSON-LD Context** (`ontologies/reqllm.context.jsonld`):
- Remove `hasContextSR` and `hasUsageSR` entries
- Add `name` entry for Tool

## New Receipt Hash

After applying clnrm changes:
- Old hash: `84461b2188fb`
- New hash: `[to be calculated after changes]`

## Verification Checklist

- [ ] Update `reqllm.sigma_observed.ttl` (remove duplicates)
- [ ] Update `reqllm.context.jsonld` (remove SR variants)
- [ ] Update `reqllm.mapping.yaml` (fix Tool.name)
- [ ] Calculate new Σ hash
- [ ] Update `reqllm.version.ttl` with new hash
- [ ] Run tests (should still pass)
- [ ] Update CI secret `SIGMA_HASH`

## Rationale

### Why merge hasContext/hasUsage?

1. **Semantic equivalence**: Both properties mean the same thing
2. **RDF best practice**: Don't duplicate properties for different domains
3. **Simpler queries**: `?x req:hasContext ?ctx` works for both Response and StreamResponse
4. **JSON-LD compatibility**: Emitters/parsers already treat them identically

### Why keep Response and StreamResponse separate?

1. **Different materialization**: Response is complete, StreamResponse is lazy
2. **Different API patterns**: `generate_text/2` vs `stream_text/2`
3. **Different runtime behavior**: StreamResponse contains enumerable
4. **Clear separation of concerns**: Final vs. incremental results

## Next Steps

1. Apply normalization changes to Σ°
2. Update JSON-LD context
3. Update mapping file
4. Calculate new hash
5. Run tests to verify
6. Document in CHANGELOG
