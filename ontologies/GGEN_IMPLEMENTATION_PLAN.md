# ggen Implementation Plan for req_llm

## Code Archaeology Summary

### What ggen Does

**ggen** is a graph-aware code generation framework that:
1. Loads RDF/OWL ontologies (Turtle, RDF/XML, JSON-LD)
2. Queries knowledge graphs with SPARQL
3. Generates code from templates using ontology data
4. Validates generated code against semantic constraints

### Key Capabilities for ACHI ggen Phase

#### 1. RDF Graph Operations
```bash
# Load our req_llm ontology
ggen graph load ontologies/reqllm.sigma_observed.ttl

# Query the ontology with SPARQL
ggen graph query "SELECT ?class WHERE { ?class a rdfs:Class }"

# Export to different formats
ggen graph export --format turtle
```

#### 2. Template-Based Code Generation
```bash
# Generate code from template with RDF context
ggen template generate -t emitter.tmpl -r ontologies/reqllm.sigma_observed.ttl

# Generate entire file tree from spec
ggen template generate-tree project.yaml --var namespace=ReqLLM
```

#### 3. AI-Powered Generation
```bash
# Generate ontologies from descriptions
ggen ai ontology -d "LLM client domain model" -o catalog.ttl

# Generate SPARQL queries from intent
ggen ai sparql -d "Find all content parts" -g ontologies/reqllm.sigma_observed.ttl

# Generate templates from descriptions
ggen ai generate -d "Elixir JSON-LD emitter" --validate
```

## Implementation Strategy for req_llm

### Phase 1: Template Creation (Manual)

**Create templates to generate Elixir code from the ontology:**

1. **`templates/elixir_emitter.tmpl`** - Generates `ReqLLM.Ontology.Emitter`
   - Input: Σ° (ontology classes + properties)
   - Output: Elixir module with `emit_*` functions
   - Uses SPARQL to query classes and properties
   - Generates JSON-LD using `reqllm.context.jsonld`

2. **`templates/elixir_parser.tmpl`** - Generates `ReqLLM.Ontology.Parser`
   - Input: Σ° (ontology schema)
   - Output: Elixir module with `parse_*` functions
   - JSON-LD → struct hydration

3. **`templates/test_suite.tmpl`** - Generates round-trip tests
   - Input: Ontology + mapping.yaml
   - Output: ExUnit tests for all entities

### Phase 2: ggen Execution

```bash
cd /Users/speed/sean/req_llm

# Generate emitter module
ggen template generate \
  -t templates/elixir_emitter.tmpl \
  -r ontologies/reqllm.sigma_observed.ttl \
  -o lib/req_llm/ontology/emitter.ex

# Generate parser module
ggen template generate \
  -t templates/elixir_parser.tmpl \
  -r ontologies/reqllm.sigma_observed.ttl \
  -o lib/req_llm/ontology/parser.ex

# Generate tests
ggen template generate \
  -t templates/test_suite.tmpl \
  -r ontologies/reqllm.sigma_observed.ttl \
  -o test/req_llm/ontology_test.exs
```

### Phase 3: CI Integration

**Add to GitHub Actions:**

```yaml
- name: Validate ontology receipts
  run: |
    EXPECTED_HASH=$(cat ontologies/reqllm.version.ttl | grep 'req:hash' | cut -d'"' -f2)
    ACTUAL_HASH=$(cat ontologies/*.ttl | sha256sum | head -c 12)
    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
      echo "Ontology drift detected!"
      exit 1
    fi

- name: Validate emitted RDF
  run: |
    # Run emitters and validate output
    mix test test/req_llm/ontology_test.exs
```

## Template Examples

### Emitter Template Structure

```yaml
---
to: "lib/req_llm/ontology/emitter.ex"
rdf_file: "ontologies/reqllm.sigma_observed.ttl"
context_file: "ontologies/reqllm.context.jsonld"
sparql:
  classes: "SELECT ?class WHERE { ?class a rdfs:Class }"
  properties: "SELECT ?prop ?domain ?range WHERE { ?prop rdfs:domain ?domain ; rdfs:range ?range }"
---
defmodule ReqLLM.Ontology.Emitter do
  @moduledoc """
  Generated from Σ° ontology using ggen.
  Emits ReqLLM structs as JSON-LD.
  """

  {% for class in sparql(query="classes") %}
  def emit_{{ class.name | snake_case }}(%ReqLLM.{{ class.name }}{} = struct) do
    # Use JSON-LD context to serialize
    # ...
  end
  {% endfor %}
end
```

## Alternative Approach: Manual Implementation

**If ggen installation is problematic**, manually implement using the artifacts we've created:

1. Use `reqllm.context.jsonld` directly in Elixir
2. Use `reqllm.mapping.yaml` to map classes → structs
3. Write emitters/parsers by hand using the ontology as spec
4. Validate against Σ° in tests

```elixir
defmodule ReqLLM.Ontology.Emitter do
  @context File.read!("ontologies/reqllm.context.jsonld") |> Jason.decode!()

  def emit_response(%ReqLLM.Response{} = response) do
    # Use @context to map struct fields → JSON-LD
    # ...
  end
end
```

## Next Steps

**Option A: Use ggen (Recommended)**
1. Fix ggen workspace configuration (cli vs crates/ggen-cli)
2. Install ggen: `cargo install --path . --force`
3. Create templates in `req_llm/templates/`
4. Run ggen to generate code
5. Run tests to validate

**Option B: Manual Implementation (Fallback)**
1. Implement `ReqLLM.Ontology.Emitter` by hand
2. Use `reqllm.context.jsonld` for JSON-LD serialization
3. Use `reqllm.mapping.yaml` for struct → ontology mappings
4. Write ExUnit tests for round-trip validation
5. Add CI checks for ontology drift

## Status

- ✅ unrdf complete (Σ° extracted)
- ✅ ggen inputs ready (JSON-LD context, mapping, queries)
- ⏸️ ggen execution blocked (installation issues)
- ⏳ Awaiting decision: Fix ggen or manual implementation?

## Evidence

- ggen repo location: `/Users/speed/sean/ggen`
- ggen docs reviewed: `ggen-ai-integration.md`, `README.md`
- Key ggen commands documented: `graph load`, `template generate`, `ai ontology`
- Templates found in: `/Users/speed/sean/ggen/crates/ggen-ai/templates/`

---

**Recommendation**: Based on the "three boss" comment (likely referring to unrdf, gitvan, clnrm), we may already have the tools needed. Consider using **manual implementation** with the artifacts we've created, then later integrate ggen when the tooling is stable.
