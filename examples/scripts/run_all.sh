#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Running all ReqLLM example scripts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

run_example() {
  local name="$1"
  shift
  echo "──────────────────────────────────────────────────────────────────────────────"
  echo "▶ $name"
  echo "──────────────────────────────────────────────────────────────────────────────"
  if "$@"; then
    echo "✓ $name completed"
  else
    echo "✗ $name failed"
    return 1
  fi
  echo ""
}

run_example "Text Generation" \
  mix run lib/examples/scripts/text_generate.exs \
  "Explain recursion in one sentence" \
  --log-level warning

run_example "Text Streaming" \
  mix run lib/examples/scripts/text_stream.exs \
  "Count from 1 to 5" \
  --log-level warning

run_example "Reasoning Tokens" \
  mix run lib/examples/scripts/reasoning_tokens.exs \
  "What is 2+2?" \
  --log-level warning

run_example "Object Generation" \
  mix run lib/examples/scripts/object_generate.exs \
  "Create a profile for a developer named Sam" \
  --log-level warning

run_example "Object Streaming" \
  mix run lib/examples/scripts/object_stream.exs \
  "Create a profile for a designer named Taylor" \
  --log-level warning

run_example "Embeddings Single" \
  mix run lib/examples/scripts/embeddings_single.exs \
  "Elixir is a functional programming language" \
  --log-level warning

run_example "Embeddings Batch Similarity" \
  mix run lib/examples/scripts/embeddings_batch_similarity.exs \
  --log-level warning

run_example "Tools Function Calling" \
  mix run lib/examples/scripts/tools_function_calling.exs \
  "What's the weather in Paris?" \
  --log-level warning

run_example "JSON Schema Examples" \
  mix run lib/examples/scripts/json_schema_examples.exs \
  --log-level warning

run_example "Context Reuse" \
  mix run lib/examples/scripts/context_reuse.exs \
  --log-level warning

run_example "Context Cross Model" \
  mix run lib/examples/scripts/context_cross_model.exs \
  --log-level warning

if [ -f "priv/examples/test.jpg" ]; then
  run_example "Multimodal Image Analysis" \
    mix run lib/examples/scripts/multimodal_image_analysis.exs \
    "Describe this image briefly" \
    --file priv/examples/test.jpg \
    --log-level warning
else
  echo "⚠️  Skipping multimodal_image_analysis.exs - priv/examples/test.jpg not found"
  echo ""
fi

if [ -f "priv/examples/test.pdf" ]; then
  run_example "Multimodal PDF Q&A" \
    mix run lib/examples/scripts/multimodal_pdf_qa.exs \
    "Summarize this document" \
    --file priv/examples/test.pdf \
    --log-level warning
else
  echo "⚠️  Skipping multimodal_pdf_qa.exs - priv/examples/test.pdf not found"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ All example scripts completed successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
