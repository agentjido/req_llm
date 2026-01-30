# Issue #351: xAI: Migrate from /v1/messages endpoint before Feb 20, 2026 deprecation

- **Issue Number:** 351
- **Title:** xAI: Migrate from /v1/messages endpoint before Feb 20, 2026 deprecation
- **Author:** [mikehostetler](https://github.com/mikehostetler)
- **Date:** January 22, 2026
- **Labels:** enhancement
- **URL:** https://github.com/agentjido/req_llm/issues/351

## Description

### Summary

xAI is deprecating the Messages endpoint (`/v1/messages`) on **February 20, 2026**. After that date, requests will return a `410 Gone` error.

### Required Action

Migrate to either:
- gRPC-based Chat service
- RESTful Responses API

### Documentation

https://docs.x.ai/docs/guides/chat

### Original Email

> The Messages endpoint (/v1/messages) will be removed from the xAI API on February 20, 2026.
> After that date, any requests sent to /v1/messages will return a 410 Gone error.
>
> We strongly recommend all xAI API users to migrate to our gRPC-based Chat service or RESTful Responses API, as these will have access to our latest features.

## Comments

*No comments*

## Resolution

**Status: Already Resolved - No Changes Needed**

Upon investigation (January 30, 2026), the xAI provider in ReqLLM is already using the correct OpenAI-compatible `/v1/chat/completions` endpoint, NOT the deprecated `/v1/messages` endpoint.

### Evidence

1. **Provider Configuration** (`lib/req_llm/providers/xai.ex` line 101):
   - `default_base_url: "https://api.x.ai/v1"`
   
2. **Endpoint Path** (inherited from `ReqLLM.Provider.Defaults` line 235):
   - `url: "/chat/completions"`
   
3. **Resulting URL**: `https://api.x.ai/v1/chat/completions`

4. **Fixtures Confirm**: All xAI test fixtures (e.g., `test/support/fixtures/xai/grok_3/basic.json`) show requests to `https://api.x.ai/v1/chat/completions`

5. **Tests Pass**: All 56 xAI provider tests pass, including the test at line 451 that explicitly asserts `request.url.path == "/chat/completions"`

### Conclusion

ReqLLM's xAI provider has always used the OpenAI-compatible Chat Completions API, not the Anthropic-style Messages API. The deprecation notice does not affect this library.

## Feedback

**Value Assessment:** ~~Critical~~ N/A - Already using correct endpoint.

**Implementation Complexity:** None - No changes required.
