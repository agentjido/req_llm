# ReqLLM Open Issues Summary

**Generated:** 2026-01-30  
**Total Open Issues:** 37

## 🔴 Critical Priority

| Issue | Title | Status |
|-------|-------|--------|
| #351 | [xAI: Migrate from /v1/messages endpoint before Feb 20, 2026 deprecation](351-xai-migrate-messages-endpoint.md) | ✅ **RESOLVED** - Already using correct endpoint |
| #356 | [Cannot upgrade past 1.2.0 due to TypedStruct conflict](356-typedstruct-conflict-upgrade.md) | Blocking upgrades |

## 🟠 Bugs (10 total)

| Issue | Title | Priority | Verified |
|-------|-------|----------|----------|
| #319 | [StreamServer timeout cascading :noproc errors](319-streamserver-timeout-cascading-noproc-errors.md) | P1 | Likely exists |
| #302 | [Property 'minimum' is not supported by Anthropic models](302-anthropic-minimum-property-not-supported.md) | P1 | Confirmed |
| #320 | [Google Provider Streaming Incompatible with OpenAI-Compatible Proxies](320-google-provider-streaming-incompatible.md) | P2 | Confirmed |
| #317 | [OpenAI, xAI don't encode non-image attachments properly](317-openai-xai-non-image-attachments.md) | P2 | Confirmed (API limit) |
| #283 | [Custom providers don't work?](283-custom-providers-dont-work.md) | P2 | Needs investigation |
| #268 | [Core Concepts has incorrect tool usage example](268-core-concepts-incorrect-tool-usage-example.md) | P2 | Confirmed |
| #146 | [Options.process restores original provider_options after translate_options](146-options-process-restores-provider-options.md) | P2 | Confirmed |
| #182 | [OpenAI *_stream behaviours](182-openai-stream-behaviours.md) | Unknown | Insufficient info |
| #297 | [Documentation for Working with Ollama](297-documentation-for-working-with-ollama.md) | P3 | Confirmed |
| #288 | [When creating new issue, "Discussion" option is a broken link](288-discussion-option-broken-link.md) | P4 | Confirmed |

## 🟢 Features & Enhancements (27 total)

### High Value / Quick Wins
| Issue | Title | Complexity |
|-------|-------|------------|
| #359 | [Allow setting up Req Attachments without low level API](359-allow-req-attachments-high-level-api.md) | Low |
| #198 | [Add support for reasoning token cost calculation](198-reasoning-token-cost.md) | Low |
| #229 | [Support additional provider options for openrouter](229-openrouter-usage-plugins.md) | Low |
| #226 | [Add support for url_context in Google provider](226-google-url-context.md) | Low |

### High Value / Medium Complexity
| Issue | Title |
|-------|-------|
| #375 | [Make Responses API the default for OpenAI](375-make-responses-api-default-openai.md) |
| #358 | [Relax strict model verification for unknown/new models](358-relax-strict-model-verification.md) |
| #314 | [Add retry logic for streaming connection failures](314-retry-logic-streaming-failures.md) |
| #259 | [Support video_url for multimodal messages](259-support-video-url-multimodal.md) |
| #257 | [OpenTelemetry stubs for model calls](257-opentelemetry-stubs-model-calls.md) |
| #236 | [Provide a mock provider like vercel ai](236-mock-provider-testing.md) |
| #187 | [Add Gemini native context caching support](187-gemini-context-caching.md) |
| #154 | [Fixture system broken for consuming applications](154-fixture-system-broken.md) |

### Medium Priority
| Issue | Title |
|-------|-------|
| #370 | [Pricing structure for 3rd party providers](370-pricing-structure-third-party-providers.md) |
| #369 | [Google cost calculation for >200k tokens](369-google-cost-calculation-200k-tokens.md) |
| #363 | [Google Imagen models support](363-google-imagen-models-support.md) |
| #255 | [Creating a custom provider for project](255-custom-provider-project.md) |
| #233 | [Refresh the model list myself](233-refresh-model-list.md) |
| #230 | [Support more than one system message](230-multiple-system-messages.md) |
| #213 | [List models available given current keys](213-list-available-models.md) |
| #196 | [Handle slightly broken JSON in structured outputs](196-handle-broken-json.md) |
| #190 | [Add reranking API support with batch processing](190-reranking-api-support.md) |
| #189 | [Cache-aware usage reporting](189-cache-aware-usage-reporting.md) |
| #188 | [Add cache extension points](188-cache-extension-points.md) |
| #203 | [Add Bumblebee Provider](203-bumblebee-provider.md) |

### Meta / Governance
| Issue | Title |
|-------|-------|
| #289 | [Library Policy on Pricing Data and Cost Calculation Accuracy](289-library-policy-pricing-cost-calculation.md) |

---

## Recommended Action Order

1. ~~**#351** - xAI endpoint migration (deadline Feb 20)~~ ✅ Already resolved
2. **#356** - TypedStruct conflict (blocking users)
3. **#319** - StreamServer timeout errors (P1 bug)
4. **#302** - Anthropic minimum property (P1 bug)
5. **#359** - Attachments API improvement (quick win)
6. **#358** - Relax model verification (high community value)
