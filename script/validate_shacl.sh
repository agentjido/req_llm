#!/usr/bin/env bash
# script/validate_shacl.sh
# Purpose: Validate RDF data against SHACL shapes using Apache Jena

set -euo pipefail

JENA_VERSION="5.2.0"
JENA_DIR="./tmp/apache-jena-${JENA_VERSION}"
JENA_BIN="${JENA_DIR}/bin/shacl"
JENA_URL="https://archive.apache.org/dist/jena/binaries/apache-jena-${JENA_VERSION}.tar.gz"

# Download and extract Apache Jena if not present
if [ ! -f "${JENA_BIN}" ]; then
  echo "📦 Downloading Apache Jena ${JENA_VERSION}..."
  mkdir -p tmp
  curl -L "${JENA_URL}" -o "tmp/jena.tar.gz"
  tar -xzf "tmp/jena.tar.gz" -C tmp
  rm "tmp/jena.tar.gz"
  echo "✅ Apache Jena installed to ${JENA_DIR}"
fi

# Default files
SHAPES="${1:-ontologies/reqllm.shapes.ttl}"
DATA="${2:-ontologies/reqllm.sigma_observed.ttl}"

echo "🔍 Validating SHACL constraints..."
echo "   Shapes: ${SHAPES}"
echo "   Data:   ${DATA}"
echo ""

# Run SHACL validation
if "${JENA_BIN}" validate --shapes "${SHAPES}" --data "${DATA}"; then
  echo ""
  echo "✅ SHACL validation PASSED"
  exit 0
else
  echo ""
  echo "❌ SHACL validation FAILED"
  exit 1
fi
