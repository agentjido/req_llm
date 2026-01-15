# Extend Google Vertex AI MIME type support to match official documentation Implementation Plan

## Overview

This plan extends the Google Vertex AI provider's MIME type inference to support all 25+ officially documented file formats for Gemini models. Currently, the provider only handles MIME types that are explicitly provided by users, with no automatic inference from file extensions. This forces users to manually specify correct MIME types when creating `ContentPart.file/3` structures, falling back to the generic `"application/octet-stream"` default when omitted.

By implementing comprehensive MIME type inference based on file extensions, we enable users to work with all Google-supported multimodal content types (images, video, audio, documents) without manually looking up MIME types, while ensuring full compatibility with Google Gemini Vertex AI's documented capabilities.

## Current State Analysis

### Existing MIME Type Handling

The Google provider currently handles MIME types in two locations:

1. **Data URI Parsing** (`lib/req_llm/providers/google.ex:1735-1755`):
   - Extracts MIME types from data URIs using regex: `data:mime/type;base64,<data>`
   - Falls back to `"image/jpeg"` if MIME type cannot be extracted
   - **Does not support regular URLs** - returns `"[Unsupported image URL]"` placeholder text

2. **File Content Part Encoding** (`lib/req_llm/providers/google.ex:1759-1768`):
   - Uses `media_type` field directly from ContentPart struct
   - No inference or validation performed
   - Relies on user-provided MIME type or default from `ContentPart.file/3`

3. **ContentPart Default** (`lib/req_llm/message/content_part.ex:62`):
   - `ContentPart.file/3` defaults to `"application/octet-stream"` when media_type is not provided
   - This generic fallback doesn't leverage Google's extensive multimodal support

### Key Discoveries

- **No existing `infer_mime_type_from_url` function**: The task description references a function that doesn't exist yet
- **Pattern matching style**: The codebase uses multi-clause function definitions with pattern matching (see `normalize_google_finish_reason/1` at line 1415-1420)
- **Test organization**: Tests are organized by feature in `describe` blocks with clear naming conventions
- **Existing helper precedent**: `lib/examples/scripts/helpers.ex:370-380` already has a `media_type/1` function for basic image inference, but it's incomplete (only 5 image types, no video/audio/documents)
- **Quality checks**: The project uses `mix quality` alias (format, compile, credo, dialyzer) for comprehensive validation

### Official Google Vertex AI Support

According to [Firebase Vertex AI documentation](https://firebase.google.com/docs/vertex-ai/input-file-requirements), Google supports **25 MIME types** across 4 categories:

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

**Note:** Extensions `.webm`, `.mp4`, and `.mpeg` are ambiguous - they can map to either video or audio MIME types depending on content. Our inference function will default to video for `.webm` and `.mp4`, and video for `.mpeg`, which are the most common use cases. Users requiring audio variants can explicitly specify the media_type.

## Desired End State

### Functional Goals

1. **New private function** `infer_mime_type_from_url/1` in `lib/req_llm/providers/google.ex`:
   - Takes a URL string (data URI, file path, or HTTP URL)
   - Extracts file extension using robust parsing (handles query params, fragments, encoding)
   - Maps extension to official Google Vertex AI MIME type
   - Returns MIME type string or `nil` for unsupported extensions
   - Case-insensitive matching (`.PNG` and `.png` both work)

2. **Integration with existing encoding**:
   - `convert_content_part/1` uses inference for URLs without explicit MIME types
   - Maintains backward compatibility - explicit `media_type` always takes precedence
   - No changes to public API surface

3. **Comprehensive test coverage**:
   - All 25 MIME types tested with representative extensions
   - Edge cases: query parameters, case sensitivity, URL fragments, unknown extensions
   - Ambiguous extensions (.webm, .mp4, .mpeg) verified to use documented defaults

### Verification Criteria

**Automated:**
- `mix test` passes with new tests for all 25 MIME types
- `mix quality` passes:
  - `mix format --check-formatted` - code formatted correctly
  - `mix compile --warnings-as-errors` - no compilation warnings
  - `mix credo --min-priority higher` - code quality checks pass
  - `mix dialyzer` - type specifications correct

**Manual:**
- Can create ContentPart with video file and get correct MIME type inference
- Can create ContentPart with audio file and get correct MIME type inference
- Can create ContentPart with document file and get correct MIME type inference
- Explicitly provided MIME types still take precedence

## What We're NOT Doing

To maintain clear scope and prevent feature creep:

- ❌ **NOT creating dedicated ContentPart.file_url or ContentPart.file_uri functions** - out of scope per task requirements
- ❌ **NOT adding MIME types not officially supported by Google Vertex AI** - only implementing documented types
- ❌ **NOT modifying other providers** - this is Google-specific functionality
- ❌ **NOT changing existing image_url API surface** - maintaining backward compatibility
- ❌ **NOT validating explicitly-provided MIME types** - trust users who provide them
- ❌ **NOT implementing content-based MIME detection** - extension-only inference
- ❌ **NOT adding automatic inference to ContentPart.file/3** - keep ContentPart provider-agnostic; inference stays in Google provider

## Implementation Approach

We'll implement this in two focused phases:

1. **Phase 1: Core MIME Type Inference** - Create the inference function with all 25 MIME types
2. **Phase 2: Integration and Testing** - Integrate with existing encoding paths and add comprehensive tests

This approach allows us to:
- Validate the inference logic independently before integration
- Test comprehensively at each layer (function, integration, edge cases)
- Maintain backward compatibility by only applying inference where MIME type is missing
- Follow existing codebase patterns (pattern matching, private helpers, test organization)

---

## Phase 1: Core MIME Type Inference Function

### Overview
Create a new private function `infer_mime_type_from_url/1` in the Google provider that maps file extensions to official Google Vertex AI MIME types.

### Changes Required

#### 1. Add MIME Type Inference Function
**File**: `lib/req_llm/providers/google.ex`
**Location**: After the `normalize_google_finish_reason/1` function (around line 1420)
**Changes**: Add new private function with comprehensive pattern matching

```elixir
@doc false
# Infer MIME type from URL file extension.
#
# Returns the appropriate MIME type for Google Vertex AI based on the file
# extension extracted from the URL, or nil if the extension is not supported.
#
# Supports all 25+ MIME types documented in Google Vertex AI official docs:
# https://firebase.google.com/docs/vertex-ai/input-file-requirements
#
# Note: For ambiguous extensions that map to multiple MIME types:
# - .webm defaults to video/webm (also used for audio)
# - .mp4 defaults to video/mp4 (also used for audio)
# - .mpeg defaults to video/mpeg (also used for audio)
#
# Users requiring specific audio MIME types should explicitly set media_type
# when creating ContentPart.file/3.
@spec infer_mime_type_from_url(String.t()) :: String.t() | nil
defp infer_mime_type_from_url(url) when is_binary(url) do
  extension =
    url
    |> extract_extension_from_url()
    |> String.downcase()

  case extension do
    # Images (3 types)
    ".png" -> "image/png"
    ".jpg" -> "image/jpeg"
    ".jpeg" -> "image/jpeg"
    ".webp" -> "image/webp"

    # Video (9 types)
    ".flv" -> "video/x-flv"
    ".mov" -> "video/quicktime"
    ".mpeg" -> "video/mpeg"
    ".mpegps" -> "video/mpegps"
    ".mpg" -> "video/mpg"
    ".mp4" -> "video/mp4"
    ".webm" -> "video/webm"
    ".wmv" -> "video/wmv"
    ".3gp" -> "video/3gpp"

    # Audio (11 types)
    ".aac" -> "audio/aac"
    ".flac" -> "audio/flac"
    ".mp3" -> "audio/mp3"
    ".m4a" -> "audio/m4a"
    ".mpga" -> "audio/mpga"
    ".opus" -> "audio/opus"
    ".pcm" -> "audio/pcm"
    ".wav" -> "audio/wav"
    # Note: .webm, .mp4, .mpeg already handled above as video (most common use case)

    # Documents (2 types)
    ".pdf" -> "application/pdf"
    ".txt" -> "text/plain"

    # Unsupported extension
    _ -> nil
  end
end

@doc false
# Extract file extension from a URL, handling query params and fragments.
#
# Examples:
#   "image.png" -> ".png"
#   "https://example.com/video.mp4?token=xyz" -> ".mp4"
#   "data:image/png;base64,..." -> "" (data URIs handled separately)
@spec extract_extension_from_url(String.t()) :: String.t()
defp extract_extension_from_url(url) when is_binary(url) do
  # Handle data URIs - no extension to extract
  if String.starts_with?(url, "data:") do
    ""
  else
    # Parse URL to handle query params and fragments
    uri = URI.parse(url)

    # Extract path (could be nil for malformed URLs)
    path = uri.path || url

    # Get extension using Path.extname which handles edge cases
    Path.extname(path)
  end
end
```

**Rationale**:
- **Pattern matching**: Follows existing codebase style (see `normalize_google_finish_reason/1`)
- **Private helpers**: Uses `defp` following existing conventions
- **Comprehensive documentation**: Includes @spec, rationale for ambiguous types, and reference to official docs
- **Case-insensitive**: Normalizes to lowercase for consistent matching
- **URL parsing**: Uses URI.parse to handle query params, fragments, and encoded characters
- **Data URI handling**: Explicitly skips data URIs (already handled by existing code)

### Success Criteria

#### Automated Verification:
- [ ] Tests pass: `mix test test/providers/google_test.exs`
- [ ] Quality checks pass: `mix quality`
  - Format: `mix format --check-formatted`
  - Compile: `mix compile --warnings-as-errors`
  - Dialyzer: `mix dialyzer`
  - Credo: `mix credo --min-priority higher`

#### Manual Verification:
- [ ] Function correctly extracts extensions from simple filenames
- [ ] Function handles URLs with query parameters
- [ ] Function handles URLs with fragments
- [ ] Function is case-insensitive
- [ ] Function returns nil for unsupported extensions

**Note**: Complete all automated verification, then pause for manual confirmation before proceeding to Phase 2.

---

## Phase 2: Integration and Comprehensive Testing

### Overview
Integrate the MIME type inference function with existing content part encoding and add comprehensive test coverage for all 25 MIME types plus edge cases.

### Changes Required

#### 1. Integrate with Content Part Encoding
**File**: `lib/req_llm/providers/google.ex`
**Location**: Modify `convert_content_part/1` for file type (around line 1759)
**Changes**: Apply inference when media_type is the default fallback

```elixir
# Most specific patterns first (file, image, etc.) - for ContentPart structs
defp convert_content_part(%{type: :file, data: data, media_type: media_type, filename: filename})
     when is_binary(data) do
  # Infer MIME type if using default fallback
  inferred_type =
    if media_type == "application/octet-stream" and is_binary(filename) do
      infer_mime_type_from_url(filename) || media_type
    else
      media_type
    end

  encoded_data = Base.encode64(data)

  %{
    inline_data: %{
      mime_type: inferred_type,
      data: encoded_data
    }
  }
end
```

**Note**: This maintains backward compatibility by:
- Only inferring when media_type is the default `"application/octet-stream"`
- Requires filename to be present for inference
- Falls back to provided media_type if inference returns nil
- Explicit media_types always take precedence

#### 2. Add Comprehensive Test Suite
**File**: `test/providers/google_test.exs`
**Location**: Add new describe block after "file attachment support" (around line 922)
**Changes**: Add comprehensive test coverage

```elixir
describe "MIME type inference from file extensions" do
  test "infers image MIME types" do
    assert Google.infer_mime_type_from_url("photo.png") == "image/png"
    assert Google.infer_mime_type_from_url("photo.jpg") == "image/jpeg"
    assert Google.infer_mime_type_from_url("photo.jpeg") == "image/jpeg"
    assert Google.infer_mime_type_from_url("image.webp") == "image/webp"
  end

  test "infers video MIME types" do
    assert Google.infer_mime_type_from_url("video.flv") == "video/x-flv"
    assert Google.infer_mime_type_from_url("video.mov") == "video/quicktime"
    assert Google.infer_mime_type_from_url("video.mpeg") == "video/mpeg"
    assert Google.infer_mime_type_from_url("video.mpegps") == "video/mpegps"
    assert Google.infer_mime_type_from_url("video.mpg") == "video/mpg"
    assert Google.infer_mime_type_from_url("video.mp4") == "video/mp4"
    assert Google.infer_mime_type_from_url("video.webm") == "video/webm"
    assert Google.infer_mime_type_from_url("video.wmv") == "video/wmv"
    assert Google.infer_mime_type_from_url("video.3gp") == "video/3gpp"
  end

  test "infers audio MIME types" do
    assert Google.infer_mime_type_from_url("audio.aac") == "audio/aac"
    assert Google.infer_mime_type_from_url("audio.flac") == "audio/flac"
    assert Google.infer_mime_type_from_url("audio.mp3") == "audio/mp3"
    assert Google.infer_mime_type_from_url("audio.m4a") == "audio/m4a"
    assert Google.infer_mime_type_from_url("audio.mpga") == "audio/mpga"
    assert Google.infer_mime_type_from_url("audio.opus") == "audio/opus"
    assert Google.infer_mime_type_from_url("audio.pcm") == "audio/pcm"
    assert Google.infer_mime_type_from_url("audio.wav") == "audio/wav"
  end

  test "infers document MIME types" do
    assert Google.infer_mime_type_from_url("document.pdf") == "application/pdf"
    assert Google.infer_mime_type_from_url("readme.txt") == "text/plain"
  end

  test "handles ambiguous extensions with video defaults" do
    # .webm defaults to video
    assert Google.infer_mime_type_from_url("file.webm") == "video/webm"

    # .mp4 defaults to video
    assert Google.infer_mime_type_from_url("file.mp4") == "video/mp4"

    # .mpeg defaults to video
    assert Google.infer_mime_type_from_url("file.mpeg") == "video/mpeg"
  end

  test "is case-insensitive" do
    assert Google.infer_mime_type_from_url("image.PNG") == "image/png"
    assert Google.infer_mime_type_from_url("video.MP4") == "video/mp4"
    assert Google.infer_mime_type_from_url("Audio.WAV") == "audio/wav"
    assert Google.infer_mime_type_from_url("DOCUMENT.PDF") == "application/pdf"
  end

  test "handles URLs with query parameters" do
    assert Google.infer_mime_type_from_url("https://example.com/video.mp4?token=xyz") ==
           "video/mp4"
    assert Google.infer_mime_type_from_url("https://cdn.com/image.png?size=large&quality=high") ==
           "image/png"
  end

  test "handles URLs with fragments" do
    assert Google.infer_mime_type_from_url("https://example.com/audio.mp3#section") ==
           "audio/mp3"
    assert Google.infer_mime_type_from_url("file.wav#timestamp=30") == "audio/wav"
  end

  test "handles encoded URLs" do
    assert Google.infer_mime_type_from_url("https://example.com/my%20video.mp4") ==
           "video/mp4"
    assert Google.infer_mime_type_from_url("path/to/my%20file.pdf") == "application/pdf"
  end

  test "returns nil for unsupported extensions" do
    assert Google.infer_mime_type_from_url("file.unknown") == nil
    assert Google.infer_mime_type_from_url("document.docx") == nil
    assert Google.infer_mime_type_from_url("archive.zip") == nil
  end

  test "returns empty string for data URIs (handled separately)" do
    data_uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    assert Google.extract_extension_from_url(data_uri) == ""
  end

  test "handles malformed URLs gracefully" do
    assert Google.infer_mime_type_from_url("not a url") == nil
    assert Google.infer_mime_type_from_url("") == nil
  end
end

describe "MIME type inference integration with ContentPart encoding" do
  test "infers MIME type for file with default application/octet-stream" do
    file_content = "test video content"

    # Create file part with default media_type and filename
    file_part = %ReqLLM.Message.ContentPart{
      type: :file,
      data: file_content,
      filename: "myvideo.mp4",
      media_type: "application/octet-stream"
    }

    message_with_file = %ReqLLM.Message{
      role: :user,
      content: [file_part]
    }

    context = %ReqLLM.Context{messages: [message_with_file]}

    mock_request = %Req.Request{
      options: [
        context: context,
        id: "gemini-1.5-flash",
        stream: false
      ]
    }

    updated_request = Google.encode_body(mock_request)
    decoded = Jason.decode!(updated_request.body)

    [user_msg] = decoded["contents"]
    [part] = user_msg["parts"]

    # Should infer video/mp4 from filename
    assert part["inline_data"]["mime_type"] == "video/mp4"
    assert Base.decode64!(part["inline_data"]["data"]) == file_content
  end

  test "respects explicit media_type over inference" do
    file_content = "audio content"

    # Explicitly specify audio/mp4 even though filename suggests video
    file_part = %ReqLLM.Message.ContentPart{
      type: :file,
      data: file_content,
      filename: "audio.mp4",
      media_type: "audio/mp4"
    }

    message_with_file = %ReqLLM.Message{
      role: :user,
      content: [file_part]
    }

    context = %ReqLLM.Context{messages: [message_with_file]}

    mock_request = %Req.Request{
      options: [
        context: context,
        id: "gemini-1.5-flash",
        stream: false
      ]
    }

    updated_request = Google.encode_body(mock_request)
    decoded = Jason.decode!(updated_request.body)

    [user_msg] = decoded["contents"]
    [part] = user_msg["parts"]

    # Should use explicit audio/mp4, not infer video/mp4
    assert part["inline_data"]["mime_type"] == "audio/mp4"
  end

  test "uses inference for various file types" do
    test_cases = [
      {"video.webm", "video content", "video/webm"},
      {"audio.flac", "audio content", "audio/flac"},
      {"document.pdf", "pdf content", "application/pdf"},
      {"notes.txt", "text content", "text/plain"}
    ]

    for {filename, content, expected_mime} <- test_cases do
      file_part = %ReqLLM.Message.ContentPart{
        type: :file,
        data: content,
        filename: filename,
        media_type: "application/octet-stream"
      }

      message_with_file = %ReqLLM.Message{
        role: :user,
        content: [file_part]
      }

      context = %ReqLLM.Context{messages: [message_with_file]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert part["inline_data"]["mime_type"] == expected_mime,
             "Expected #{expected_mime} for #{filename}, got #{part["inline_data"]["mime_type"]}"
    end
  end

  test "falls back to application/octet-stream for unsupported extensions" do
    file_content = "unknown content"

    file_part = %ReqLLM.Message.ContentPart{
      type: :file,
      data: file_content,
      filename: "file.unknown",
      media_type: "application/octet-stream"
    }

    message_with_file = %ReqLLM.Message{
      role: :user,
      content: [file_part]
    }

    context = %ReqLLM.Context{messages: [message_with_file]}

    mock_request = %Req.Request{
      options: [
        context: context,
        id: "gemini-1.5-flash",
        stream: false
      ]
    }

    updated_request = Google.encode_body(mock_request)
    decoded = Jason.decode!(updated_request.body)

    [user_msg] = decoded["contents"]
    [part] = user_msg["parts"]

    # Should keep application/octet-stream since extension is not supported
    assert part["inline_data"]["mime_type"] == "application/octet-stream"
  end
end
```

**Note**: These tests require making `infer_mime_type_from_url/1` and `extract_extension_from_url/1` testable. We have two options:
1. Add `@doc false` and test private functions directly (common in Elixir)
2. Only test through public integration (encode_body)

Given the complexity and importance of edge cases, we'll use option 1 - testing private functions directly with `@doc false` annotation.

### Success Criteria

#### Automated Verification:
- [ ] All tests pass: `mix test`
- [ ] Quality checks pass: `mix quality`
  - Format: `mix format --check-formatted`
  - Compile: `mix compile --warnings-as-errors`
  - Dialyzer: `mix dialyzer`
  - Credo: `mix credo --min-priority higher`

#### Manual Verification:
- [ ] Creating ContentPart.file with video extension infers correct MIME type
- [ ] Creating ContentPart.file with audio extension infers correct MIME type
- [ ] Creating ContentPart.file with document extension infers correct MIME type
- [ ] Explicitly provided MIME types override inference
- [ ] Unsupported extensions fall back to application/octet-stream
- [ ] All 25 official Google MIME types are covered

**Note**: Complete all automated verification, then pause for manual confirmation before marking this phase complete.

---

## Testing Strategy

### Unit Tests
- **MIME type inference function**: Test all 25 MIME types with representative extensions
- **Extension extraction**: Test URL parsing with query params, fragments, encoded characters
- **Edge cases**: Case sensitivity, unknown extensions, data URIs, malformed URLs
- **Ambiguous extensions**: Verify default behavior for .webm, .mp4, .mpeg

### Integration Tests
- **ContentPart encoding**: Verify inference is applied when media_type is default
- **Explicit MIME types**: Verify explicitly provided types take precedence
- **Various file types**: Test video, audio, document inference end-to-end
- **Fallback behavior**: Verify unsupported extensions keep default media_type

### Manual Testing Steps
After implementation, manually verify:

1. **Video file support**:
   ```elixir
   file = ContentPart.file(video_bytes, "demo.mp4")
   # Verify Google encoding uses video/mp4 MIME type
   ```

2. **Audio file support**:
   ```elixir
   file = ContentPart.file(audio_bytes, "song.mp3")
   # Verify Google encoding uses audio/mp3 MIME type
   ```

3. **Document support**:
   ```elixir
   file = ContentPart.file(pdf_bytes, "doc.pdf")
   # Verify Google encoding uses application/pdf MIME type
   ```

4. **Explicit override**:
   ```elixir
   file = ContentPart.file(audio_bytes, "audio.mp4", "audio/mp4")
   # Verify Google encoding uses audio/mp4, not video/mp4
   ```

5. **Unsupported extension**:
   ```elixir
   file = ContentPart.file(data, "file.unknown")
   # Verify falls back to application/octet-stream
   ```

## Migration Notes

No migration required. This change:
- Adds new functionality without breaking existing code
- Maintains backward compatibility with explicit media_type specifications
- Only affects Google provider, not other providers
- Does not change public API surface (ContentPart, Context, etc.)

Users currently specifying media_types will see no change. Users relying on defaults will automatically benefit from improved MIME type inference.

## References

- **Research**: `/Users/mhostetler/Source/ReqLLM/req_llm/.wreckit/items/001-extend-google-vertex-ai-mime-type-support-to-match/research.md`
- **Official Google Documentation**: https://firebase.google.com/docs/vertex-ai/input-file-requirements
- **Current Implementation**: `lib/req_llm/providers/google.ex:1735-1780`
- **ContentPart Module**: `lib/req_llm/message/content_part.ex:61-63`
- **Existing Tests**: `test/providers/google_test.exs:814-922`
- **Helper Example**: `lib/examples/scripts/helpers.ex:370-380`
