# Fix Streaming Race Condition Issue #42

## Issue Description

Users are experiencing a BadMapError when using the streaming functionality with OpenAI provider in req_llm. The error occurs consistently when streaming is enabled.

**Steps to reproduce:**
1. Configure req_llm with OpenAI provider
2. Enable streaming by setting `stream: true` in options
3. Make a request for text generation
4. Observe BadMapError crash

**Expected:** Streaming responses should work correctly, returning chunks of text as they arrive
**Actual:** Application crashes with `BadMapError: expected a map, got: [into: #Function<...>]`
**Impact:** Critical - streaming functionality is completely broken

## Root Cause Analysis

### Investigation Findings

After analyzing the codebase and error patterns, the root cause has been identified:

1. **Double Request Execution**: The code incorrectly executes the same HTTP request twice:
   - First execution: In `ReqLLM.Generation.stream_text/2` at line 230
   - Second execution: In `ReqLLM.Provider.Defaults.decode_streaming_response/1` at line 547

2. **Race Condition Mechanism**:
   - When streaming is enabled, `ReqLLM.Step.Stream.maybe_attach/1` configures the request with an `:into` callback
   - The first `Req.request(request)` call initiates the HTTP request with the streaming callback
   - Meanwhile, `decode_streaming_response` spawns an async Task that attempts to execute `Req.request(req, into: into_callback)` again
   - This second request execution causes the BadMapError because the request struct has already been consumed

3. **Error Source**:
   - The Req library expects a fresh request struct for each execution
   - When the second `Req.request` is called with `[into: into_callback]` options
   - The request struct is in an invalid state, causing Req to receive unexpected data types
   - This manifests as the BadMapError when Req tries to merge options

### Where the Issue Originates

**File:** `lib/req_llm/provider/defaults.ex`
**Lines:** 544-547
**Function:** `decode_streaming_response/1`

### Why It's Happening

The implementation misunderstands how Req streaming works. When `attach_real_time` sets up streaming:
1. It creates a Stream.resource with the `:into` callback
2. Stores this callback in the request's private data
3. The callback is automatically used when `Req.request` is called

The bug is that the code then tries to execute the request AGAIN with the same callback, causing a race condition and state corruption.

## Solution Overview

Remove the duplicate request execution in `decode_streaming_response`. The streaming is already set up and executing from the first `Req.request` call. We just need to return the configured stream without making another HTTP request.

### Key Technical Decisions
- Keep the stream setup in `attach_real_time` unchanged
- Remove the async Task that makes the duplicate request
- Simply return the already-configured stream

### Alternative Approaches Considered
1. **Modify attach_real_time to not execute request**: Rejected because this would require restructuring the entire streaming flow
2. **Add state tracking to prevent double execution**: Rejected as overly complex when the fix is simply removing duplicate code
3. **Use a different streaming mechanism**: Rejected as the current approach works fine without the duplicate request

## Technical Details

- **File to modify:** `lib/req_llm/provider/defaults.ex`
- **Function:** `decode_streaming_response/1`
- **Lines to change:** 544-565
- **Dependencies:** No new dependencies required
- **Backwards compatibility:** Fix maintains API compatibility

## Testing Strategy

- Verify streaming works with OpenAI provider
- Test that chunks arrive in real-time
- Ensure non-streaming requests still work
- Validate error handling in streaming mode
- Test concurrent streaming requests
- Add regression test for the race condition

## Rollback Plan

- If issues arise, revert the changes to `defaults.ex`
- No configuration or data changes required
- Monitor for any streaming-related errors post-deployment

## Implementation Plan

- [x] Create fix branch (already on bug/streaming-race-condition)
- [ ] Write investigation notes documenting the issue
- [ ] Reproduce the issue with test case
- [ ] Implement the fix in defaults.ex
- [ ] Test the fix thoroughly
- [ ] Add regression tests
- [ ] Run all tests to ensure no regressions
- [ ] Update fix documentation with results

## Current Status

**What's broken:** Streaming requests crash with BadMapError due to double request execution
**What's fixed:** Not yet fixed - investigation complete
**How to test:** Enable streaming with OpenAI provider and make a text generation request