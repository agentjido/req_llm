#!/usr/bin/env bash
# script/compose_ontology.sh
# Purpose: Compose Σ + ΣΔ into unified graph (unrdf phase)

set -euo pipefail

ONTOLOGIES_DIR="ontologies"
OUTPUT_DIR="graph"
OUTPUT_FILE="$OUTPUT_DIR/reqllm.ttl"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "==> unrdf: Composing ontology graph..."

# Merge all TTL files
cat > "$OUTPUT_FILE" <<'HEADER'
@prefix req: <https://schema.reqllm.dev#> .
@prefix ex: <http://example.org/domain#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

# ============================================================
# ReqLLM Unified Ontology (Σ + ΣΔ)
# Composed from: reqllm.sigma_observed.ttl + reqllm.feature.failover.ttl
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ============================================================

HEADER

# Append base ontology (skip header lines)
echo "  - Merging reqllm.sigma_observed.ttl"
grep -v "^@prefix" "$ONTOLOGIES_DIR/reqllm.sigma_observed.ttl" | \
  grep -v "^#" | \
  grep -v "^$" >> "$OUTPUT_FILE"

echo "" >> "$OUTPUT_FILE"
echo "# ---------- Budget-Aware Failover Extension (ΣΔ) ----------" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Append feature delta (skip header lines)
echo "  - Merging reqllm.feature.failover.ttl"
grep -v "^@prefix" "$ONTOLOGIES_DIR/reqllm.feature.failover.ttl" | \
  grep -v "^#" | \
  grep -v "^$" >> "$OUTPUT_FILE"

# Calculate hash
ONTOLOGY_HASH=$(sha256sum "$OUTPUT_FILE" | cut -c1-12)

echo "✅ Composed ontology: $OUTPUT_FILE"
echo "📊 Hash: $ONTOLOGY_HASH"
echo "hash(unrdf_compose)=$ONTOLOGY_HASH"

# Verify file is valid Turtle (basic check)
if ! grep -q "rdfs:Class" "$OUTPUT_FILE"; then
  echo "❌ Error: Output doesn't look like valid Turtle"
  exit 1
fi

echo "✅ Basic validation passed"
