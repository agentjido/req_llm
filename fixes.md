# ReqLLM Scripts - Issues and Fixes

## Testing Summary

All scripts have been implemented and tested. Below are the results and any issues discovered.

## Scripts Implemented

### Core Generation
1. ✅ `lib/scripts/text_generate.exs` - Non-streaming text generation
2. ✅ `lib/scripts/text_stream.exs` - Streaming text generation
3. ✅ `lib/scripts/object_generate.exs` - Non-streaming object generation
4. ✅ `lib/scripts/object_stream.exs` - Streaming object generation

### Embeddings
5. ✅ `lib/scripts/embeddings_single.exs` - Single text embedding
6. ✅ `lib/scripts/embeddings_batch_similarity.exs` - Batch embeddings with similarity

### Tools and Schemas
7. ✅ `lib/scripts/tools_function_calling.exs` - Tool/function calling
8. ✅ `lib/scripts/json_schema_examples.exs` - JSON schema patterns

### Multimodal
9. ✅ `lib/scripts/multimodal_image_analysis.exs` - Vision/image analysis
10. ✅ `lib/scripts/multimodal_pdf_qa.exs` - PDF document analysis

### Shared Module
11. ✅ `lib/scripts/helpers.ex` - Shared helper functions

## Issues Discovered

### 1. Streaming Usage Metadata Not Available
**Script:** `text_stream.exs`
**Issue:** StreamChunk metadata doesn't include usage information, so final usage stats aren't displayed after streaming completes.
**Severity:** Low
**Status:** Known limitation - streaming usage may be available in metadata_task but not consistently across providers
**Workaround:** Usage is available in non-streaming variants

### 2. OpenAI Object Generation Schema Encoding Bug
**Script:** `object_generate.exs`, `object_stream.exs`
**Issue:** OpenAI provider has a bug where raw schema keyword lists are serialized instead of compiled JSON schemas when using `json_schema` response format.
**Severity:** Medium
**Status:** Known issue - affects OpenAI models only
**Workaround:** Use Anthropic models for object generation examples, or use `openai_structured_output_mode: :tool_strict` option
**Related:** This was the original bug that prompted removal of object examples from getting-started.livemd

### 3. PDF Support Added to Anthropic Provider
**Script:** `multimodal_pdf_qa.exs`
**Issue:** PDF document support wasn't implemented in Anthropic context encoder
**Severity:** None (fixed)
**Status:** ✅ Fixed - Added `:file` content part encoding support to `lib/req_llm/providers/anthropic/context.ex`
**Implementation:** Extracts base64 data and media_type from ContentPart.File structs and encodes as Anthropic document blocks

## Test Results

### Text Generation Tests
```bash
# Basic text generation
mix run lib/scripts/text_generate.exs "Explain functional programming in one sentence"
✅ SUCCESS - Generated concise explanation

# With system message
mix run lib/scripts/text_generate.exs "Hello" -s "You are a pirate" 
✅ SUCCESS - Response in pirate style

# Different model
mix run lib/scripts/text_generate.exs "Hi" -m anthropic:claude-3-5-haiku-20241022
✅ SUCCESS - Works with Anthropic
```

### Streaming Tests
```bash
# Basic streaming
mix run lib/scripts/text_stream.exs "Write a haiku about rivers"
✅ SUCCESS - Tokens streamed in real-time

# With parameters
mix run lib/scripts/text_stream.exs "Tell a story" --max-tokens 100 --temperature 0.9
✅ SUCCESS - Parameters applied correctly
```

### Object Generation Tests
```bash
# Basic object with Anthropic (works)
mix run lib/scripts/object_generate.exs "Create a profile for Alice" -m anthropic:claude-3-5-haiku-20241022
✅ SUCCESS - Valid JSON object generated

# Streaming object with Anthropic
mix run lib/scripts/object_stream.exs "Extract: Jane, 32, Berlin" -m anthropic:claude-3-5-haiku-20241022
✅ SUCCESS - Valid JSON object streamed

# Note: OpenAI has schema encoding bug, use Anthropic for reliable results
```

### Embeddings Tests
```bash
# Single embedding
mix run lib/scripts/embeddings_single.exs "Elixir is functional"
✅ SUCCESS - Generated 1536-dim embedding

# Batch with similarity
mix run lib/scripts/embeddings_batch_similarity.exs
✅ SUCCESS - Computed pairwise similarities, correctly identified most/least similar
```

### Tools Tests
```bash
# Weather query
mix run lib/scripts/tools_function_calling.exs "What's the weather in Paris?"
✅ SUCCESS - Called get_weather tool with correct args

# Multi-tool query (default prompt)
mix run lib/scripts/tools_function_calling.exs
✅ SUCCESS - Called all 3 tools (weather, joke, time)
```

### Schema Examples Tests
```bash
# Multiple schema patterns
mix run lib/scripts/json_schema_examples.exs -m anthropic:claude-3-5-haiku-20241022
✅ SUCCESS - Generated 3 different objects (person, product, event)
```

### Multimodal Tests
```bash
# Image analysis
mix run lib/scripts/multimodal_image_analysis.exs "Describe this" --file priv/examples/test.jpg
✅ SUCCESS - Analyzed image content correctly (OpenAI & Anthropic)

# PDF analysis
mix run lib/scripts/multimodal_pdf_qa.exs "Summarize" --file priv/examples/test.pdf
✅ SUCCESS - Extracted and summarized PDF content (Anthropic)
```

## Recommendations

### For Users
1. **Object Generation**: Use Anthropic models for most reliable results until OpenAI schema bug is fixed
2. **PDF Analysis**: Use Anthropic Claude models - best PDF support
3. **Image Analysis**: Both OpenAI gpt-4o-mini and Anthropic claude-3-5-haiku work well
4. **Embeddings**: OpenAI text-embedding-3-small is default and works reliably

### For Developers
1. **Fix OpenAI Schema Bug**: The `lib/req_llm/providers/openai.ex` encoder needs to convert schemas using `ReqLLM.Schema.to_json/1` before serialization
2. **Streaming Metadata**: Consider adding usage metadata to StreamResponse or final meta chunk
3. **Error Messages**: Current error handling via Helpers.handle_error! is comprehensive and helpful

## Performance Notes

- Text generation: ~1-3 seconds typical
- Streaming: Tokens appear within ~500ms, full response ~2-4 seconds
- Object generation: ~2-5 seconds (schema validation overhead)
- Embeddings: ~300-800ms for single, ~1-2s for batch of 5
- Tools: ~2-4 seconds (single round trip)
- Image analysis: ~2-5 seconds (depends on image size)
- PDF analysis: ~3-8 seconds (depends on document size)

## Conclusion

All 11 scripts are functional and demonstrate the main ReqLLM API methods effectively. The only significant issue is the OpenAI schema encoding bug for object generation, which has a known workaround (use Anthropic or tool_strict mode).
