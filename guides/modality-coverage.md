# Modality Coverage Map

This guide documents the ReqLLM v2 scenario taxonomy across text and non-text
modalities. It is a planning and guardrail document: it names the behavior
surface that should stay protected while provider wire-format internals are
refactored.

Routine validation remains replay-first. Do not record live fixtures unless a
scenario prompt, request shape, options, schema, media payload, or provider
behavior intentionally changes.

## Proof Levels

- `fixture_backed` - covered by replay fixtures today.
- `unit_guarded` - covered by unit or provider encoding/decoding tests, but not
  yet represented by replay fixture scenarios.
- `mixed_proof` - some fixture-backed coverage exists, but adjacent behavior is
  still mostly provider/unit guarded.
- `macro_available` - a provider coverage macro exists, but no focused coverage
  file currently uses it.

## Scenario Taxonomy

| Area | Operation | Modality | Proof | Scenario IDs |
| --- | --- | --- | --- | --- |
| `core` | `text` | text | `fixture_backed` | `basic`, `usage`, `token_limit` |
| `conversation` | `text` | text | `fixture_backed` | `context_append` |
| `streaming` | `text` | text | `fixture_backed` | `streaming` |
| `tools` | `text` | tool | `fixture_backed` | `tool_none`, `tool_multi`, `tool_round_trip` |
| `objects` | `text` | structured output | `fixture_backed` | `object_basic`, `object_streaming` |
| `reasoning` | `text` | reasoning | `fixture_backed` | `reasoning` |
| `embedding` | `embedding` | embedding vectors | `fixture_backed` | `embed_basic`, `embed_usage`, `embed_batch` |
| `image` | `image` | image output | `fixture_backed` | `image_basic` |
| `transcription` | `transcription` | audio input | `fixture_backed` | `transcription_basic` |
| `speech` | `speech` | audio output | `fixture_backed` | `speech_basic` |
| `rerank` | `rerank` | ranking | `fixture_backed` | `rerank_basic` |
| `ocr` | `ocr` | document input | `macro_available` | `ocr_basic` |
| `grounding` | `text` | web tool | `fixture_backed` | `grounding_basic`, `grounding_with_context`, `grounding_streaming` |
| `grounding_legacy` | `text` | web tool | `fixture_backed` | `grounding_legacy` |
| `multimodal_tool_result` | `text` | document input | `fixture_backed` | `multimodal_tool_result` |
| `web_search` | `text` | web tool | `fixture_backed` | `web_search_basic`, `web_search_streaming`, `x_search_streaming` |
| `web_fetch` | `text` | web tool | `fixture_backed` | `web_fetch_basic` |
| `streaming_structured_output` | `text` | structured output | `fixture_backed` | `object_streaming_json_schema`, `object_streaming_tool_strict`, `object_streaming_auto`, `streaming_error_handling` |
| `vision_input` | `text` | vision input | `unit_guarded` | none |
| `file_input` | `text` | document input | `mixed_proof` | none |
| `media_url_content` | `text` | media URL | `unit_guarded` | none |
| `audio_output_chat` | `text` | audio output | `unit_guarded` | none |

The machine-checkable source for this table is
`ReqLLM.Test.Scenarios.ModalityTaxonomy` in
`test/support/scenarios/modality_taxonomy.ex`.

## Current Fixture-Backed Providers

Focused non-text and provider-specific coverage is routed through
`mix req_llm.model_compat` when a matching capability or scenario is requested.

| Area | Focused Coverage Files |
| --- | --- |
| `embedding` | `test/coverage/amazon_bedrock/embedding_test.exs`, `test/coverage/azure/embedding_test.exs`, `test/coverage/google/embedding_test.exs`, `test/coverage/google_vertex_gemini/embedding_test.exs`, `test/coverage/openai/embedding_test.exs`, `test/coverage/openrouter/embedding_test.exs` |
| `image` | `test/coverage/google/image_generation_test.exs`, `test/coverage/openai/image_generation_test.exs`, `test/coverage/xai/image_generation_test.exs` |
| `transcription` | `test/coverage/groq/transcription_test.exs`, `test/coverage/openai/transcription_test.exs` |
| `speech` | `test/coverage/elevenlabs/speech_test.exs`, `test/coverage/openai/speech_test.exs` |
| `rerank` | `test/coverage/cohere/rerank_test.exs` |
| `grounding`, `grounding_legacy` | `test/coverage/google/grounding_test.exs` |
| `multimodal_tool_result` | `test/coverage/google/multimodal_tool_result_test.exs` |
| `web_search` | `test/coverage/anthropic/web_search_test.exs`, `test/coverage/openai/web_search_test.exs`, `test/coverage/xai/web_search_test.exs` |
| `web_fetch` | `test/coverage/anthropic/web_fetch_test.exs` |
| `streaming_structured_output` | `test/coverage/anthropic/streaming_structured_output_test.exs`, `test/coverage/azure/streaming_structured_output_test.exs`, `test/coverage/xai/streaming_structured_output_test.exs` |

## Known Gaps

These are intentional visibility gaps, not failures in the current suite.

- `ocr_basic` has a provider coverage macro but no focused coverage file.
- Vision input is mostly protected by provider/unit tests for image binary,
  image URL, and mixed text/image encoding.
- File input has focused Google multimodal-tool-result coverage, but broader
  PDF/file-id/provider rejection behavior is still provider/unit guarded.
- Video URL and media URL content parts are tested at message/context/provider
  encoding boundaries, not as live replay scenarios.
- Audio-output chat behavior is provider/unit guarded; speech generation itself
  is fixture-backed through `speech_basic`.
- Image edit, source image, and mask options are unit-guarded; `image_basic`
  currently proves only basic image generation.

## Brainstormed Next Epics

This list is brainstormed and subject to change. Items should be promoted into
separate Beadwork epics before implementation.

- Promote OCR into focused fixture-backed coverage once a stable provider/model
  target is selected.
- Add vision-input replay scenarios for image binary, image URL, and mixed
  text/image messages.
- Add document-input replay scenarios for file IDs, inline PDFs, OpenRouter
  file-parser behavior, and OpenAI Responses file handling.
- Split image generation into basic generation, edit/source image, mask, and
  provider option scenarios.
- Add audio-output chat scenarios for models that return text plus audio
  metadata or transcripts.
- Add video/media URL replay coverage where providers support it, and explicit
  rejection scenarios where they do not.
- Convert focused non-text provider macros into reusable scenario modules once
  the taxonomy is stable.
