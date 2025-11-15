# ReqLLM Example Scripts

Standalone, runnable examples demonstrating ReqLLM's main API methods. All scripts are executable via `mix run` and suitable for documentation.

## Quick Start

```bash
# Text generation
mix run lib/examples/scripts/text_generate.exs "Explain functional programming"

# Streaming text
mix run lib/examples/scripts/text_stream.exs "Write a haiku about code"

# Object generation (use Anthropic for best results)
mix run lib/examples/scripts/object_generate.exs "Create a profile for Alice" -m anthropic:claude-3-5-haiku-20241022

# Image analysis
mix run lib/examples/scripts/multimodal_image_analysis.exs "What's in this image?" --file priv/examples/test.jpg
```

## Scripts Overview

### Text Generation

#### `text_generate.exs` - Basic text generation
Non-streaming text generation with full response metadata.

```bash
mix run lib/examples/scripts/text_generate.exs "Your prompt here" [options]

Options:
  --model, -m MODEL       Model spec (default: openai:gpt-4o-mini)
  --system, -s SYSTEM     System prompt/message
  --max-tokens TOKENS     Maximum tokens to generate
  --temperature TEMP      Sampling temperature (0.0-2.0)
  --log-level, -l LEVEL   Output verbosity (warning|info|debug)

Examples:
  # Basic usage
  mix run lib/examples/scripts/text_generate.exs "Explain neural networks"
  
  # With system message
  mix run lib/examples/scripts/text_generate.exs "Hello" -s "You are a pirate"
  
  # Different model with parameters
  mix run lib/examples/scripts/text_generate.exs "Tell a joke" \
    -m anthropic:claude-3-5-haiku-20241022 \
    --temperature 0.9 \
    --max-tokens 100
```

#### `text_stream.exs` - Streaming text generation
Real-time token streaming as the model generates.

```bash
mix run lib/examples/scripts/text_stream.exs "Your prompt here" [options]

Options:
  Same as text_generate.exs

Examples:
  # Watch tokens appear in real-time
  mix run lib/examples/scripts/text_stream.exs "Write a story about a robot"
  
  # With creative parameters
  mix run lib/examples/scripts/text_stream.exs "Compose a poem" \
    --temperature 1.2 \
    -s "You are a romantic poet"
```

#### `reasoning_tokens.exs` - Reasoning token usage
Demonstrates extended thinking with reasoning-capable models.

```bash
mix run lib/examples/scripts/reasoning_tokens.exs "Your prompt here" [options]

Options:
  --model, -m MODEL                 Model spec (default: openai:o1-mini)
  --max-tokens TOKENS               Maximum tokens to generate
  --temperature TEMP                Sampling temperature
  --reasoning-effort EFFORT         Reasoning effort: low, medium, high
  --reasoning-token-budget BUDGET   Maximum reasoning tokens
  --thinking-visibility VIS         Thinking visibility: final, hidden
  --log-level, -l LEVEL             Output verbosity

Examples:
  # Basic reasoning
  mix run lib/examples/scripts/reasoning_tokens.exs \
    "Explain quantum entanglement"
  
  # High effort with token budget
  mix run lib/examples/scripts/reasoning_tokens.exs \
    "Solve this complex logic puzzle" \
    --reasoning-effort high \
    --reasoning-token-budget 1000
  
  # Control thinking visibility
  mix run lib/examples/scripts/reasoning_tokens.exs \
    "Analyze this algorithm" \
    --thinking-visibility hidden
```

### Object Generation

#### `object_generate.exs` - Structured object generation
Generate validated JSON objects matching a schema.

**Note:** Works with both OpenAI and Anthropic. Ensure all schema fields have `required: true` for OpenAI strict mode.

```bash
mix run lib/examples/scripts/object_generate.exs "Your prompt here" [options]

Options:
  --model, -m MODEL       Model spec (default: anthropic:claude-3-5-haiku-20241022)
  --max-tokens TOKENS     Maximum tokens
  --temperature TEMP      Sampling temperature
  --log-level, -l LEVEL   Output verbosity

Schema: Person (name, age, occupation, location)

Examples:
  # Generate person profile
  mix run lib/examples/scripts/object_generate.exs \
    "Create a profile for a software engineer named Alice" \
    -m anthropic:claude-3-5-haiku-20241022
  
  # Extract structured data from text
  mix run lib/examples/scripts/object_generate.exs \
    "Extract info: John Smith, 35, lawyer in Boston" \
    -m anthropic:claude-sonnet-4-5-20250929
```

#### `object_stream.exs` - Streaming object generation
Generate objects with real-time updates.

```bash
mix run lib/examples/scripts/object_stream.exs "Your prompt here" [options]

Options:
  Same as object_generate.exs

Schema: Person (name, age, occupation, location)

Examples:
  mix run lib/examples/scripts/object_stream.exs \
    "Create a character profile" \
    -m anthropic:claude-3-5-haiku-20241022
```

### Embeddings

#### `embeddings_single.exs` - Single text embedding
Generate embedding vector for a single text.

```bash
mix run lib/examples/scripts/embeddings_single.exs "Your text here" [options]

Options:
  --model, -m MODEL       Embedding model (default: openai:text-embedding-3-small)
  --log-level, -l LEVEL   Output verbosity

Examples:
  # Generate embedding
  mix run lib/examples/scripts/embeddings_single.exs "Elixir is a functional language"
  
  # Use large model
  mix run lib/examples/scripts/embeddings_single.exs "Deep learning" \
    -m openai:text-embedding-3-large
```

#### `embeddings_batch_similarity.exs` - Batch embeddings with similarity
Generate embeddings for multiple texts and compute similarities.

```bash
mix run lib/examples/scripts/embeddings_batch_similarity.exs [options]

Options:
  --model, -m MODEL       Embedding model (default: openai:text-embedding-3-small)
  --log-level, -l LEVEL   Output verbosity

Examples:
  # Compute similarities (uses built-in text list)
  mix run lib/examples/scripts/embeddings_batch_similarity.exs
  
  # With different model
  mix run lib/examples/scripts/embeddings_batch_similarity.exs \
    -m google:text-embedding-004
```

### Tools and Schemas

#### `tools_function_calling.exs` - Function calling with tools
Demonstrate tool/function calling capabilities.

```bash
mix run lib/examples/scripts/tools_function_calling.exs "Your prompt here" [options]

Options:
  --model, -m MODEL       Model spec (default: openai:gpt-4o-mini)
  --max-tokens TOKENS     Maximum tokens
  --temperature TEMP      Sampling temperature
  --log-level, -l LEVEL   Output verbosity

Tools: get_weather, tell_joke, get_time

Examples:
  # Single tool call
  mix run lib/examples/scripts/tools_function_calling.exs \
    "What's the weather in Paris in Celsius?"
  
  # Multi-tool call (uses default prompt)
  mix run lib/examples/scripts/tools_function_calling.exs
  
  # With Anthropic
  mix run lib/examples/scripts/tools_function_calling.exs \
    "Tell me a joke about programming" \
    -m anthropic:claude-3-5-haiku-20241022
```

#### `json_schema_examples.exs` - JSON schema patterns
Demonstrate various schema patterns and object generation.

```bash
mix run lib/examples/scripts/json_schema_examples.exs [options]

Options:
  --model, -m MODEL       Model spec (default: openai:gpt-4o-mini)
  --log-level, -l LEVEL   Output verbosity

Demonstrates:
  1. Simple person schema (name, age, occupation)
  2. Product schema (name, price, category, features, in_stock)
  3. Event schema with enums and constraints

Examples:
  # Run all three examples with OpenAI
  mix run lib/examples/scripts/json_schema_examples.exs
  
  # Or with Anthropic
  mix run lib/examples/scripts/json_schema_examples.exs \
    -m anthropic:claude-3-5-haiku-20241022
```

### Multimodal

#### `multimodal_image_analysis.exs` - Vision/image analysis
Analyze images with vision-capable models.

```bash
mix run lib/examples/scripts/multimodal_image_analysis.exs "Your prompt" --file PATH [options]

Options:
  --file FILE             Image file path (REQUIRED)
  --model, -m MODEL       Vision model (default: openai:gpt-4o-mini)
  --max-tokens TOKENS     Maximum tokens
  --temperature TEMP      Sampling temperature
  --log-level, -l LEVEL   Output verbosity

Supported formats: PNG, JPEG, JPG, WEBP, GIF

Examples:
  # Analyze image
  mix run lib/examples/scripts/multimodal_image_analysis.exs \
    "Describe this image in detail" \
    --file priv/examples/test.jpg
  
  # With Anthropic
  mix run lib/examples/scripts/multimodal_image_analysis.exs \
    "What objects are visible?" \
    --file photo.png \
    -m anthropic:claude-3-5-haiku-20241022
  
  # Quiet mode (content only)
  mix run lib/examples/scripts/multimodal_image_analysis.exs \
    "What do you see?" \
    --file image.jpg \
    -l warning
```

#### `multimodal_pdf_qa.exs` - PDF document analysis
Analyze and query PDF documents (Anthropic Claude only).

```bash
mix run lib/examples/scripts/multimodal_pdf_qa.exs "Your prompt" --file PATH [options]

Options:
  --file FILE             PDF file path (REQUIRED)
  --model, -m MODEL       Model spec (default: anthropic:claude-3-5-haiku-20241022)
  --max-tokens TOKENS     Maximum tokens
  --temperature TEMP      Sampling temperature
  --log-level, -l LEVEL   Output verbosity

Provider support: Anthropic Claude only

Examples:
  # Summarize PDF
  mix run lib/examples/scripts/multimodal_pdf_qa.exs \
    "Summarize the key points" \
    --file document.pdf
  
  # Ask specific question
  mix run lib/examples/scripts/multimodal_pdf_qa.exs \
    "What are the main conclusions?" \
    --file research_paper.pdf \
    -m anthropic:claude-sonnet-4-5-20250929
  
  # Extract specific info
  mix run lib/examples/scripts/multimodal_pdf_qa.exs \
    "List all mentioned dates" \
    --file report.pdf \
    --max-tokens 500
```

## Common Options

All scripts support these common flags:

- `--model, -m MODEL` - Override default model
- `--log-level, -l LEVEL` - Control output verbosity
  - `warning` - Content only (quiet, good for docs)
  - `info` - Include model info and timing (default)
  - `debug` - Verbose internal details
- `--max-tokens TOKENS` - Limit response length
- `--temperature TEMP` - Control randomness (0.0-2.0)
- `--system, -s SYSTEM` - Set system prompt (text generation only)

## Default Models

Models are configured in `config/config.exs`:

- **Text generation**: `openai:gpt-4o-mini` (first in `:sample_text_models`)
- **Object generation**: Anthropic recommended due to OpenAI schema bug
- **Embeddings**: `openai:text-embedding-3-small` (first in `:sample_embedding_models`)
- **Vision**: `openai:gpt-4o-mini` (supports images)
- **PDF**: `anthropic:claude-3-5-haiku-20241022` (only provider with PDF support)

## API Keys

Scripts use `ReqLLM.get_key/1` to retrieve API keys. Set them via:

1. **Environment variables** (recommended):
   ```bash
   export OPENAI_API_KEY=sk-...
   export ANTHROPIC_API_KEY=sk-ant-...
   export GOOGLE_API_KEY=...
   ```

2. **Application config**:
   ```elixir
   # config/dev.exs
   config :req_llm,
     openai_api_key: "sk-...",
     anthropic_api_key: "sk-ant-..."
   ```

3. **Direct pass** (not recommended for production):
   ```bash
   # Not supported in scripts, but available in API
   ReqLLM.generate_text(model, prompt, api_key: "sk-...")
   ```

## Example Data

Test files are provided in `priv/examples/`:

- `test.jpg` - Sample image for vision analysis (400x300 Lorem Picsum)
- `test.pdf` - Sample PDF for document analysis

Create your own test data:

```bash
# Download test image
curl -o priv/examples/my_image.jpg "https://picsum.photos/800/600"

# Create simple PDF (requires ps2pdf)
echo "Test document content" | ps2pdf - priv/examples/my_doc.pdf
```

## Known Issues

See [fixes.md](../../fixes.md) for complete issue tracking.

### OpenAI Strict Mode Requirements
OpenAI's strict mode requires all schema fields to be marked as `required: true`. The library handles this automatically for proper schemas:

```elixir
# ✅ Correct - fields marked as required
schema = [
  name: [type: :string, required: true],
  age: [type: :integer, required: true]
]

# ❌ May fail with OpenAI - missing required flags
schema = [
  name: [type: :string],
  age: [type: :integer]
]
```

### PDF Support
Only Anthropic Claude models support PDF analysis:

```bash
# ✅ Supported
-m anthropic:claude-3-5-haiku-20241022
-m anthropic:claude-sonnet-4-5-20250929

# ❌ Not supported
-m openai:gpt-4o-mini
-m google:gemini-2.0-flash
```

## Usage in Documentation

All scripts are designed for documentation purposes:

1. **Copy-paste runnable** - Commands work as-is
2. **Deterministic output** - Low temperature defaults
3. **Clean output** - Use `-l warning` for content-only
4. **Consistent interface** - Similar flags across all scripts
5. **Error guidance** - Helpful messages for common issues

Example for docs:

```markdown
Generate a person profile:

\`\`\`bash
mix run lib/examples/scripts/object_generate.exs \
  "Create a software engineer profile" \
  -m anthropic:claude-3-5-haiku-20241022 \
  -l warning
\`\`\`

Output:
\`\`\`json
{
  "name": "Sarah Chen",
  "age": 32,
  "occupation": "Senior Software Engineer",
  "location": "San Francisco, CA"
}
\`\`\`
```

## Contributing

When adding new scripts:

1. Use `ReqLLM.Scripts.Helpers` for common functionality
2. Follow existing patterns for argument parsing
3. No comments in function bodies (AGENTS.md rule)
4. Test with multiple providers when applicable
5. Document in this README
6. Add test results to `fixes.md`

## Support

For issues or questions:
- File an issue: https://github.com/agentjido/req_llm/issues
- Check fixes.md for known issues
- Review AGENTS.md for coding conventions
