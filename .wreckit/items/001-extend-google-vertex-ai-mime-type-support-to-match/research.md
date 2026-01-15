# Research: Extend Google Vertex AI MIME type support to match official documentation

**Date**: 2026-01-15
**Item**: 001-extend-google-vertex-ai-mime-type-support-to-match

## Research Question
The Google provider's MIME type inference is incomplete, supporting only 11 of 25+ officially supported MIME types, which may cause valid file formats to fall back to application/octet-stream or fail to work properly with Gemini models.

**Motivation:** Ensure full compatibility with Google Gemini Vertex AI's documented capabilities and provide users with complete multimodal support for all officially supported file types.

**Success criteria:**
- All 25+ MIME types from official Google Vertex AI documentation are supported
- File extension to MIME type mapping covers: images (3), video (9), audio (11), documents (2)
- Comprehensive tests verify correct MIME type inference for all supported extensions
- Edge cases handled (query params, case sensitivity, unknown extensions)

**Technical constraints:**
- Must maintain backward compatibility with existing 11 MIME types
- Must follow Google Vertex AI official documentation (January 2026)
- Implementation in lib/req_llm/providers/google.ex infer_mime_type_from_url function

**In scope:**
- Add missing video formats: .flv, .mov, .mpeg, .mpegps, .mpg, .webm, .wmv, .3gp
- Add missing audio formats: .aac, .flac, .mpga, .opus, .ogg, .webm
- Add missing document format: .txt
- Map to correct MIME types: video/x-flv, video/quicktime, video/mpeg, video/mpegps, video/mpg, video/webm, video/wmv, video/3gpp, audio/aac, audio/flac, audio/mpga, audio/opus, audio/webm, text/plain
- Add tests for all new MIME types
- Verify against official sources: firebase.google.com/docs/vertex-ai/input-file-requirements

**Out of scope:**
- Creating dedicated ContentPart.file_url or ContentPart.file_uri functions
- Adding MIME types not officially supported by Google Vertex AI
- Modifying other providers
- Changing existing image_url API surface

**Signals:** priority: high, urgency: User requested thorough fix with comprehensive testing

## Summary

The task is to extend MIME type support in the Google Vertex AI provider to match official Google documentation. Currently, the codebase handles MIME types through data URI parsing in the `convert_content_part/1` function within `lib/req_llm/providers/google.ex` (around lines 1735-1768). However, there is **no existing `infer_mime_type_from_url` function** as mentioned in the task description.

The current implementation extracts MIME types from data URIs (format: `data:mime/type;base64,<data>`) using regex parsing, but does not infer MIME types from file extensions in regular URLs. This means users must manually specify correct MIME types when creating `ContentPart.file/3` or `ContentPart.image/2` structures.

Based on the official Google Firebase Vertex AI documentation, there are **25 officially supported MIME types** across 4 categories: images (3), video (9), audio (11), and documents (2). The solution requires creating a new MIME type inference mechanism that can detect file extensions from URLs (including those with query parameters) and map them to the correct MIME type according to Google's specifications.

## Current State Analysis

### Existing Implementation

**MIME Type Handling - Current Approach:**

The Google provider currently handles MIME types in two key locations:

1. **Data URI Parsing** (`lib/req_llm/providers/google.ex:1735-1750`):
```elixir
defp convert_content_part(%{type: "image_url", image_url: %{url: url}}) when is_binary(url) do
  # Parse data URI format: data:mime/type;base64,<data>
  case String.split(url, ",", parts: 2) do
    [header, base64_data] ->
      mime_type =
        case Regex.run(~r/data:([^;]+)/, header) do
          [_, type] -> type
          _ -> "image/jpeg"
        end

      %{
        inline_data: %{
          mime_type: mime_type,
          data: base64_data
        }
      }
    _ ->
      # Not a data URI, might be a URL
      %{text: "[Unsupported image URL]"}
  end
end
```

This function extracts MIME types from data URIs but **falls back to a placeholder text for regular URLs** rather than inferring the MIME type from the file extension.

2. **File Content Part Encoding** (`lib/req_llm/providers/google.ex:1759-1768`):
```elixir
defp convert_content_part(%{type: :file, data: data, media_type: media_type})
     when is_binary(data) do
  encoded_data = Base.encode64(data)

  %{
    inline_data: %{
      mime_type: media_type,
      data: encoded_data
    }
  }
end
```

This function uses the `media_type` field directly as provided by the user, with no inference or validation.

**ContentPart Module** (`lib/req_llm/message/content_part.ex:61-63`):

The `ContentPart.file/3` function has a default MIME type:
```elixir
@spec file(binary(), String.t(), String.t()) :: t()
def file(data, filename, media_type \\ "application/octet-stream"),
  do: %__MODULE__{type: :file, data: data, filename: filename, media_type: media_type}
```

The default of `"application/octet-stream"` is a generic fallback that doesn't leverage Google's extensive multimodal support.

### Key Files

- `lib/req_llm/providers/google.ex:1735-1780` - Content part conversion functions handling MIME types
- `lib/req_llm/message/content_part.ex:61-63` - ContentPart.file/3 constructor with default MIME type
- `lib/req_llm/provider/defaults.ex:651-666` - OpenAI-compatible file encoding (also uses media_type directly)
- `test/providers/google_test.exs` - Main provider tests (no MIME type inference tests found)
- `test/providers/google_images_test.exs` - Image-specific tests

### Official Google Vertex AI MIME Type Support

According to the official Firebase documentation (firebase.google.com/docs/vertex-ai/input-file-requirements), Google Vertex AI supports:

**Images (3 types):**
- `.png` → `image/png`
- `.jpg`, `.jpeg` → `image/jpeg`
- `.webp` → `image/webp`

**Video (9 types):**
- `.flv` → `video/x-flv`
- `.mov` → `video/quicktime`
- `.mpeg` → `video/mpeg`
- `.mpegps` → `video/mpegps`
- `.mpg` → `video/mpg`
- `.mp4` → `video/mp4`
- `.webm` → `video/webm`
- `.wmv` → `video/wmv`
- `.3gp` → `video/3gpp`

**Audio (11 types):**
- `.aac` → `audio/aac`
- `.flac` → `audio/flac`
- `.mp3` → `audio/mp3`
- `.m4a` → `audio/m4a`
- `.mpeg` → `audio/mpeg`
- `.mpga` → `audio/mpga`
- `.mp4` → `audio/mp4`
- `.opus` → `audio/opus`
- `.pcm` → `audio/pcm`
- `.wav` → `audio/wav`
- `.webm` → `audio/webm`

**Documents (2 types):**
- `.pdf` → `application/pdf`
- `.txt` → `text/plain`

**Important Note:** Some extensions like `.webm`, `.mp4`, and `.mpeg` map to multiple MIME types depending on content type. The inference function will need to handle ambiguous cases appropriately.

## Technical Considerations

### Dependencies

**Internal modules to integrate with:**
- `ReqLLM.Message.ContentPart` - The ContentPart struct definitions
- `ReqLLM.Providers.Google` - The Google provider implementation
- `URI` module - For URL parsing to extract file extensions

**External dependencies:**
- None required - this is a pure Elixir implementation using standard library functions

### Patterns to Follow

**1. Private Helper Functions:**
The Google provider follows a pattern of using private `defp` functions for encoding/decoding logic:
```elixir
defp convert_content_part(%{type: :file, ...}) do
  # conversion logic
end
```

**2. Pattern Matching for Extension Extraction:**
Use pattern matching and guard clauses similar to existing finish_reason normalization:
```elixir
defp normalize_google_finish_reason("STOP"), do: "stop"
defp normalize_google_finish_reason("MAX_TOKENS"), do: "length"
```

**3. URL Parsing:**
Need to handle URLs with:
- Query parameters: `https://example.com/video.mp4?token=xyz`
- URL fragments: `https://example.com/audio.mp3#section`
- Encoded characters: `https://example.com/my%20file.wav`

**4. Test Structure:**
Follow the existing test pattern in `test/providers/google_test.exs`:
```elixir
describe "mime type inference" do
  test "infers image MIME types from extensions" do
    # test assertions
  end
end
```

**5. Documentation Pattern:**
Use `@doc` and `@spec` following existing conventions:
```elixir
@doc """
Infer MIME type from URL file extension.

Returns the appropriate MIME type for Google Vertex AI based on the file
extension, or nil if the extension is not supported.
"""
@spec infer_mime_type_from_url(String.t()) :: String.t() | nil
```

### Implementation Strategy

**Location:** `lib/req_llm/providers/google.ex`

**New Function:** Create `infer_mime_type_from_url/1` as a private helper function

**Integration Points:**

1. Modify `convert_content_part/1` for `image_url` type (line ~1735) to call the new inference function for non-data-URI URLs
2. Optionally update `ContentPart.file/3` default behavior (requires careful consideration for backward compatibility)
3. Add comprehensive tests in `test/providers/google_test.exs`

**Ambiguous Extension Handling:**

Some extensions map to multiple MIME types:
- `.webm` → can be `video/webm` or `audio/webm`
- `.mp4` → can be `video/mp4` or `audio/mp4`
- `.mpeg` → can be `video/mpeg` or `audio/mpeg`

**Recommended approach:** Default to the most common use case (video for `.webm` and `.mp4`, video for `.mpeg`) but document this clearly. Users requiring specific MIME types can still explicitly set them via `ContentPart.file/3`.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Breaking backward compatibility** | High | Keep existing default behavior for `ContentPart.file/3`; only infer MIME types when not explicitly provided |
| **Ambiguous file extensions** | Medium | Document the default behavior for ambiguous extensions (.webm, .mp4, .mpeg); provide clear guidance for users who need specific types |
| **URL parsing edge cases** | Medium | Use robust URI parsing with `URI.parse/1` and handle query parameters, fragments, and encoded characters properly |
| **Case sensitivity** | Low | Normalize extensions to lowercase before matching: `String.downcase(ext)` |
| **Missing official documentation changes** | Medium | Add source URL as documentation comment; make it easy to update if Google changes supported types |
| **Performance overhead** | Low | MIME type inference is a simple string operation with pattern matching - minimal overhead |

## Recommended Approach

**Phase 1: Create MIME Type Inference Function**

1. Add a private `infer_mime_type_from_url/1` function in `lib/req_llm/providers/google.ex`
2. Implement extension extraction with proper URL parsing:
   - Use `URI.parse/1` to handle query params and fragments
   - Use `Path.extname/1` to extract extension
   - Normalize to lowercase for case-insensitive matching
3. Use pattern matching for all 25 MIME types with clear categorization
4. Return `nil` for unsupported extensions

**Phase 2: Integration**

1. Modify `convert_content_part/1` for non-data-URI image URLs to use inference
2. Consider adding inference as a fallback in the file encoding path
3. Maintain backward compatibility - only use inference when MIME type is not explicitly provided

**Phase 3: Testing**

1. Create comprehensive test suite covering:
   - All 25 supported MIME types (grouped by category)
   - Edge cases: query parameters, fragments, case insensitivity
   - Unknown extensions (should return nil or default)
   - Ambiguous extensions (verify documented default behavior)
2. Follow existing test patterns in `test/providers/google_test.exs`
3. Add integration tests showing end-to-end usage with actual ContentPart creation

**Phase 4: Documentation**

1. Add inline documentation with official Google source link
2. Update moduledoc if needed to mention MIME type inference capability
3. Consider adding example usage to guides if applicable

## Open Questions

1. **Should MIME type inference be applied to `ContentPart.file/3` at creation time, or only when encoding for the Google provider?**
   - **Recommendation:** Only apply in the Google provider's encoding path to maintain provider independence and avoid affecting other providers.

2. **How should we handle the ambiguous extensions (.webm, .mp4, .mpeg)?**
   - **Recommendation:** Default to video for `.webm` and `.mp4`, video for `.mpeg`. Document this clearly in the function documentation and allow users to override by explicitly setting media_type.

3. **Should we validate that explicitly-provided MIME types are in the supported list?**
   - **Recommendation:** No validation - allow users to provide any MIME type in case Google adds new support. Only infer when MIME type is missing.

4. **Should inference work for data URIs that lack a MIME type (e.g., filename in data URI)?**
   - **Recommendation:** Data URIs should always include MIME types per RFC 2397. If missing, fall back to inference based on any filename hints, but this is an edge case.

5. **Should we add a helper function for users to check supported MIME types?**
   - **Recommendation:** Out of scope for this task, but could be a future enhancement: `Google.supported_mime_types()` → list of all supported types.
