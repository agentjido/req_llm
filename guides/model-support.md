# Model Support Evidence

This file is generated from `priv/model_compat_scenarios.json` and the compiled
compatibility scenario catalog. It is a tooling snapshot, not a runtime model
allowlist, and it does not change whether ReqLLM can resolve or call a model.

- Evidence schema: `1`
- Snapshot evaluated at: `2026-07-17T14:17:49Z`
- Freshness window: `90 days`

## Conservative tier rules

- **First-class**: every fixture-replay baseline scenario for this exact
  execution surface has current passing evidence.
- **Best-effort**: at least one baseline scenario has current passing evidence,
  but the baseline is incomplete.
- **Experimental**: evidence is missing, stale, or no fixture-replay baseline is
  defined. Catalog presence alone never promotes a surface.
- **Unsupported**: a required baseline scenario has explicit failing evidence;
  the reason includes its classified failure layer.

A recorded operation that current model metadata does not declare is unsupported
for that operation. Evidence for a model absent from the current catalog remains
experimental rather than becoming a support claim.

These labels describe evidence for a model surface. They do not describe every
provider-native feature and are not consulted by request routing.

## Snapshot summary

| Tier | Surfaces |
| --- | ---: |
| First-class | 47 |
| Best-effort | 475 |
| Experimental | 66 |
| Unsupported | 103 |
| **Total recorded surfaces** | **691** |

## anthropic

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `claude-haiku-4-5-20251001` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:09:16Z | missing current evidence: context_append, streaming |
| `claude-opus-4-1-20250805` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:11:25Z | missing current evidence: context_append, streaming |
| `claude-opus-4-20250514` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:13:32Z | missing current evidence: context_append, streaming |
| `claude-opus-4-5` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:20:43Z | missing current evidence: context_append, streaming |
| `claude-opus-4-8` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:14:45Z | missing current evidence: context_append, streaming |
| `claude-sonnet-4-20250514` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:16:20Z | missing current evidence: context_append, streaming |
| `claude-sonnet-4-5-20250929` | `text` | `anthropic.messages` | text → text | Best-effort | 3/5 | 2026-05-29T17:17:58Z | missing current evidence: context_append, streaming |

## cerebras

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `gpt-oss-120b` | `text` | `cerebras.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:27:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `llama3.1-8b` | `text` | `cerebras.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:27:04Z | surface declaration unknown |
| `qwen-3-235b-a22b-instruct-2507` | `text` | `cerebras.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:27:04Z | basic failed at provider_drift |
| `qwen-3-coder-480b` | `text` | `cerebras.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:27:04Z | basic failed at provider_drift |
| `zai-glm-4.7` | `text` | `cerebras.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:27:04Z | missing current evidence: usage, token_limit, context_append, streaming |

## cohere

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `c4ai-aya-expanse-32b` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `c4ai-aya-expanse-8b` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `c4ai-aya-vision-32b` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `c4ai-aya-vision-8b` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-a-03-2025` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-a-reasoning-08-2025` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-a-translate-08-2025` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-a-vision-07-2025` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-r-08-2024` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-r-plus-08-2024` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-r7b-12-2024` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `command-r7b-arabic-02-2025` | `text` | `cohere.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:28:02Z | basic failed at assertion |
| `rerank-english-v3.0` | `rerank` | `cohere.rerank` | text → ranked_documents | First-class | 1/1 | 2026-05-29T23:28:38Z | complete current baseline |
| `rerank-multilingual-v3.0` | `rerank` | `cohere.rerank` | text → ranked_documents | First-class | 1/1 | 2026-05-29T23:28:38Z | complete current baseline |
| `rerank-v3.5` | `rerank` | `cohere.rerank` | text → ranked_documents | First-class | 1/1 | 2026-05-29T23:28:38Z | complete current baseline |
| `rerank-v4.0-fast` | `rerank` | `cohere.rerank` | text → ranked_documents | First-class | 1/1 | 2026-05-29T23:28:38Z | complete current baseline |
| `rerank-v4.0-pro` | `rerank` | `cohere.rerank` | text → ranked_documents | First-class | 1/1 | 2026-05-29T23:28:38Z | complete current baseline |

## elevenlabs

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `eleven_flash_v2_5` | `speech` | `elevenlabs.speech` | text → audio | First-class | 1/1 | 2026-05-29T23:29:10Z | complete current baseline |
| `eleven_multilingual_v2` | `speech` | `elevenlabs.speech` | text → audio | First-class | 1/1 | 2026-05-29T23:29:10Z | complete current baseline |
| `eleven_turbo_v2_5` | `speech` | `elevenlabs.speech` | text → audio | First-class | 1/1 | 2026-05-29T23:29:10Z | complete current baseline |
| `eleven_v3` | `speech` | `elevenlabs.speech` | text → audio | First-class | 1/1 | 2026-05-29T23:29:10Z | complete current baseline |

## fireworks_ai

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `accounts/fireworks/models/deepseek-v4-flash` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/deepseek-v4-pro` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/glm-5p1` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/gpt-oss-120b` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/gpt-oss-20b` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/kimi-k2p5` | `text` | `fireworks_ai.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:30:47Z | surface declaration unknown |
| `accounts/fireworks/models/kimi-k2p6` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/minimax-m2p5` | `text` | `fireworks_ai.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:30:47Z | surface declaration unknown |
| `accounts/fireworks/models/minimax-m2p7` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |
| `accounts/fireworks/models/qwen3p6-plus` | `text` | `fireworks_ai.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:30:47Z | surface declaration unknown |
| `accounts/fireworks/routers/glm-5p1-fast` | `text` | `fireworks_ai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:30:47Z | basic failed at provider_drift |
| `accounts/fireworks/routers/kimi-k2p6-turbo` | `text` | `fireworks_ai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:30:47Z | missing current evidence: usage, token_limit, context_append, streaming |

## github_copilot

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `gpt-4.1` | `text` | `github_copilot.chat_completions` | text → text | Best-effort | 1/5 | 2026-06-12T21:58:25Z | missing current evidence: usage, token_limit, context_append, streaming |

## google

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `antigravity-preview-05-2026` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `aqa` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `deep-research-max-preview-04-2026` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `deep-research-preview-04-2026` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `deep-research-pro-preview-12-2025` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-1.5-flash` | `text` | `google.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `gemini-1.5-pro` | `text` | `google.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `gemini-2.0-flash` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-2.0-flash-exp` | `text` | `google.generate_content` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `gemini-2.0-flash-lite` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-2.5-computer-use-preview-10-2025` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-2.5-flash` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-2.5-flash-image` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:27:26Z | complete current baseline |
| `gemini-2.5-flash-lite` | `text` | `google.generate_content` | text, tool_result → structured_object, text, tool_call | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-2.5-flash-native-audio-latest` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-2.5-flash-native-audio-preview-09-2025` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-2.5-flash-native-audio-preview-12-2025` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-2.5-pro` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-3-flash-preview` | `text` | `google.generate_content` | text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-3-pro-image` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:29:02Z | complete current baseline |
| `gemini-3-pro-image-preview` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:28:39Z | complete current baseline |
| `gemini-3-pro-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-3.1-flash-image` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:28:17Z | complete current baseline |
| `gemini-3.1-flash-image-preview` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:27:52Z | complete current baseline |
| `gemini-3.1-flash-lite` | `text` | `google.generate_content` | text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-3.1-flash-lite-preview` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-3.1-flash-live-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-3.1-pro-preview` | `text` | `google.generate_content` | document, text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-3.1-pro-preview-customtools` | `text` | `google.generate_content` | text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-3.5-flash` | `text` | `google.generate_content` | text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-06-10T21:03:14Z | complete current baseline |
| `gemini-embedding-001` | `embedding` | `google.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T01:02:06Z | missing current evidence: embed_usage, embed_batch |
| `gemini-embedding-2` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | operation not declared |
| `gemini-embedding-2-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-flash-latest` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-pro-latest` | `text` | `google.generate_content` | text → text | First-class | 5/5 | 2026-05-30T01:01:43Z | complete current baseline |
| `gemini-robotics-er-1.5-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `gemini-robotics-er-1.6-preview` | `text` | `google.generate_content` | text → text | Best-effort | 1/5 | 2026-05-30T01:01:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `imagen-4.0-fast-generate-001` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:29:31Z | complete current baseline |
| `imagen-4.0-generate-001` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:29:18Z | complete current baseline |
| `imagen-4.0-ultra-generate-001` | `image` | `google.image` | text → image | First-class | 1/1 | 2026-05-29T22:29:47Z | complete current baseline |
| `lyria-3-clip-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `lyria-3-pro-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `nano-banana-pro-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at assertion |
| `text-embedding-004` | `embedding` | `google.unrecorded_embedding` | text → embedding | Experimental | 0/3 | 2026-05-30T01:02:06Z | surface declaration unknown |
| `veo-2.0-generate-001` | `text` | `google.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `veo-3.0-fast-generate-001` | `text` | `google.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `veo-3.0-generate-001` | `text` | `google.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:01:43Z | surface declaration unknown |
| `veo-3.1-fast-generate-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `veo-3.1-generate-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |
| `veo-3.1-lite-generate-preview` | `text` | `google.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:01:43Z | basic failed at provider_drift |

## groq

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `allam-2-7b` | `text` | `groq.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:26:10Z | surface declaration unknown |
| `groq/compound` | `text` | `groq.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:26:10Z | basic failed at provider_drift |
| `groq/compound-mini` | `text` | `groq.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:26:10Z | basic failed at provider_drift |
| `llama-3.1-8b-instant` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `llama-3.3-70b-versatile` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `llama3-8b-8192` | `text` | `groq.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:26:10Z | surface declaration unknown |
| `meta-llama/llama-4-maverick-17b-128e-instruct` | `text` | `groq.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:26:10Z | surface declaration unknown |
| `meta-llama/llama-prompt-guard-2-22m` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-prompt-guard-2-86m` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2-instruct-0905` | `text` | `groq.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:26:10Z | surface declaration unknown |
| `openai/gpt-oss-120b` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-20b` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-safeguard-20b` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-32b` | `text` | `groq.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:26:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `whisper-large-v3` | `transcription` | `groq.transcription` | audio → text | First-class | 1/1 | 2026-05-29T23:26:29Z | complete current baseline |
| `whisper-large-v3-turbo` | `transcription` | `groq.transcription` | audio → text | First-class | 1/1 | 2026-05-29T23:26:29Z | complete current baseline |

## meta

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `muse-spark-1.1` | `text` | `meta.responses` | text, tool_result → reasoning, structured_object, text, tool_call | First-class | 5/5 | 2026-07-17T14:17:49Z | complete current baseline |

## minimax

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `MiniMax-M2.1` | `text` | `minimax.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T16:18:48Z | basic failed at provider_drift |

## openai

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `babbage-002` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T19:05:19Z | basic failed at provider_drift |
| `chat-latest` | `text` | `openai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T21:30:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `chatgpt-image-latest` | `image` | `openai.image` | text → image | First-class | 1/1 | 2026-05-29T21:24:36Z | complete current baseline |
| `davinci-002` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T19:05:29Z | basic failed at provider_drift |
| `gpt-4-0125-preview` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T19:05:48Z | basic failed at provider_drift |
| `gpt-4.1-2025-04-14` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:57:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-4.1-mini` | `text` | `openai.unrecorded_text` | text → text | Best-effort | 1/5 | 2026-05-29T18:43:47Z | missing current evidence: basic, usage, token_limit, streaming |
| `gpt-4.1-mini-2025-04-14` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:57:38Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-4o-2024-08-06` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:57:48Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-4o-2024-11-20` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:57:58Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-4o-mini` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T16:16:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-4o-mini-transcribe` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T21:19:21Z | complete current baseline |
| `gpt-4o-mini-transcribe-2025-03-20` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T21:23:21Z | complete current baseline |
| `gpt-4o-mini-transcribe-2025-12-15` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T21:23:38Z | complete current baseline |
| `gpt-4o-mini-tts` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T21:17:40Z | complete current baseline |
| `gpt-4o-mini-tts-2025-12-15` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T21:17:57Z | complete current baseline |
| `gpt-4o-transcribe` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T21:20:10Z | complete current baseline |
| `gpt-4o-transcribe-diarize` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T21:23:56Z | complete current baseline |
| `gpt-5-2025-08-07` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:58:08Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5-mini-2025-08-07` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:58:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5-nano` | `text` | `openai.unrecorded_text` | text → structured_object | Experimental | 0/5 | 2026-05-29T18:43:47Z | missing or stale evidence |
| `gpt-5-nano-2025-08-07` | `text` | `openai.responses` | text → text | Best-effort | 2/5 | 2026-05-29T19:19:08Z | missing current evidence: usage, token_limit, context_append |
| `gpt-5-pro` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:59:05Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5-pro-2025-10-06` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:59:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5-search-api` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T19:09:22Z | basic failed at provider_drift |
| `gpt-5-search-api-2025-10-14` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T19:09:31Z | basic failed at provider_drift |
| `gpt-5.1` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.1-2025-11-13` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:26Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.2` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.2-2025-12-11` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:43Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.2-chat-latest` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:53Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.2-pro` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:01:09Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.2-pro-2025-12-11` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:01:31Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.3-chat-latest` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:05:58Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.3-codex` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:06:08Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.3-codex-spark` | `text` | `openai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T21:26:57Z | basic failed at provider_drift |
| `gpt-5.4` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:06:26Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-2026-03-05` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:06:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-mini` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:06:44Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-mini-2026-03-17` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:06:53Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-nano` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:07:01Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-nano-2026-03-17` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:07:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-pro` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:07:49Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.4-pro-2026-03-05` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:08:23Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.5` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:08:33Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.5-2026-04-23` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:08:42Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.5-pro` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:08:53Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-5.5-pro-2026-04-23` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:09:14Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-audio` | `text` | `openai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T21:37:41Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-audio-mini` | `text` | `openai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T21:37:57Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gpt-image-1-mini` | `image` | `openai.image` | text → image | First-class | 1/1 | 2026-05-29T21:25:04Z | complete current baseline |
| `gpt-image-1.5` | `image` | `openai.image` | text → image | First-class | 1/1 | 2026-05-29T20:45:07Z | complete current baseline |
| `gpt-image-2` | `image` | `openai.image` | text → image | First-class | 1/1 | 2026-05-29T21:25:32Z | complete current baseline |
| `gpt-image-2-2026-04-21` | `image` | `openai.image` | text → image | First-class | 1/1 | 2026-05-29T21:26:05Z | complete current baseline |
| `gpt-realtime-whisper` | `transcription` | `openai.unrecorded_transcription` | audio → text | Unsupported | 0/1 | 2026-05-29T21:20:41Z | transcription_basic failed at assertion |
| `o3-2025-04-16` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:58:41Z | missing current evidence: usage, token_limit, context_append, streaming |
| `o3-pro` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T18:59:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `o3-pro-2025-06-10` | `text` | `openai.responses` | text → text | Best-effort | 1/5 | 2026-05-29T19:00:08Z | missing current evidence: usage, token_limit, context_append, streaming |
| `tts-1` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T20:40:07Z | complete current baseline |
| `tts-1-1106` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T21:18:14Z | complete current baseline |
| `tts-1-hd` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T21:18:32Z | complete current baseline |
| `tts-1-hd-1106` | `speech` | `openai.speech` | text → audio | First-class | 1/1 | 2026-05-29T21:18:50Z | complete current baseline |
| `whisper-1` | `transcription` | `openai.transcription` | audio → text | First-class | 1/1 | 2026-05-29T20:44:37Z | complete current baseline |

## openrouter

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `aion-labs/aion-1.0` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:24:39Z | surface declaration unknown |
| `aion-labs/aion-1.0-mini` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:24:39Z | surface declaration unknown |
| `aion-labs/aion-2.0` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:39Z | missing current evidence: usage, token_limit, context_append, streaming |
| `aion-labs/aion-rp-llama-3.1-8b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:39Z | missing current evidence: usage, token_limit, context_append, streaming |
| `amazon/nova-2-lite-v1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `amazon/nova-lite-v1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `amazon/nova-micro-v1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `amazon/nova-premier-v1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `amazon/nova-pro-v1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:28Z | missing current evidence: usage, token_limit, context_append, streaming |
| `arcee-ai/coder-large` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:13:54Z | basic failed at provider_drift |
| `arcee-ai/maestro-reasoning` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:13:54Z | surface declaration unknown |
| `arcee-ai/spotlight` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:13:54Z | surface declaration unknown |
| `arcee-ai/trinity-large-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:13:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `arcee-ai/trinity-mini` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:13:54Z | surface declaration unknown |
| `arcee-ai/virtuoso-large` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:13:54Z | basic failed at provider_drift |
| `baai/bge-base-en-v1.5` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `baai/bge-large-en-v1.5` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `baai/bge-m3` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `baidu/ernie-4.5-21b-a3b` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:14:36Z | surface declaration unknown |
| `baidu/ernie-4.5-21b-a3b-thinking` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:14:36Z | surface declaration unknown |
| `baidu/ernie-4.5-300b-a47b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:14:36Z | surface declaration unknown |
| `baidu/ernie-4.5-vl-28b-a3b` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:14:36Z | surface declaration unknown |
| `baidu/ernie-4.5-vl-424b-a47b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:14:36Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance-seed/seed-1.6` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:07Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance-seed/seed-1.6-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:07Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance-seed/seed-2.0-lite` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:07Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance-seed/seed-2.0-mini` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:07Z | missing current evidence: usage, token_limit, context_append, streaming |
| `cohere/command-a` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:25Z | missing current evidence: usage, token_limit, context_append, streaming |
| `cohere/command-r-08-2024` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:25Z | missing current evidence: usage, token_limit, context_append, streaming |
| `cohere/command-r-plus-08-2024` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:25Z | missing current evidence: usage, token_limit, context_append, streaming |
| `cohere/command-r7b-12-2024` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:25Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-chat` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-chat-v3-0324` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-r1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-r1-0528` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-r1-distill-llama-70b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-r1-distill-qwen-32b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:35:21Z | surface declaration unknown |
| `deepseek/deepseek-v3.2` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v3.2-exp` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v3.2-speciale` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:35:21Z | surface declaration unknown |
| `deepseek/deepseek-v4-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v4-flash:free` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:35:21Z | surface declaration unknown |
| `deepseek/deepseek-v4-pro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:35:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.0-flash-001` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:24:06Z | surface declaration unknown |
| `google/gemini-2.0-flash-lite-001` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:24:06Z | surface declaration unknown |
| `google/gemini-2.5-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:06Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-flash-lite` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:06Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-flash-lite-preview-09-2025` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:24:06Z | surface declaration unknown |
| `google/gemini-2.5-pro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:06Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-pro-preview` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:06Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-pro-preview-05-06` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:06Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3-flash-preview` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-flash-lite` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-flash-lite-preview` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-pro-preview` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-pro-preview-customtools` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.5-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:15:55Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-embedding-001` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `google/gemini-embedding-2-preview` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `google/gemma-2-27b-it` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-3-4b-it` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-3n-e4b-it` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-4-26b-a4b-it` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-4-26b-a4b-it:free` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:42:35Z | basic failed at provider_drift |
| `google/gemma-4-31b-it` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-4-31b-it:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `ibm-granite/granite-4.0-h-micro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:20:36Z | missing current evidence: usage, token_limit, context_append, streaming |
| `ibm-granite/granite-4.1-8b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:20:36Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inception/mercury-2` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:20:46Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ling-2.6-1t` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:16:15Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ling-2.6-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:16:15Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ring-2.6-1t` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:16:15Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inflection/inflection-3-pi` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inflection/inflection-3-productivity` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:24:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `intfloat/e5-base-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `intfloat/e5-large-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `intfloat/multilingual-e5-large` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `liquid/lfm-2-24b-a2b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:16:50Z | surface declaration unknown |
| `liquid/lfm-2.5-1.2b-instruct:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:16:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `liquid/lfm-2.5-1.2b-thinking:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:16:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mancer/weaver` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:25:07Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3-70b-instruct` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:37:04Z | surface declaration unknown |
| `meta-llama/llama-3-8b-instruct` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:37:04Z | surface declaration unknown |
| `meta-llama/llama-3.1-70b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3.1-8b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3.2-11b-vision-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3.2-1b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3.2-3b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-3.2-3b-instruct:free` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:37:04Z | basic failed at provider_drift |
| `meta-llama/llama-3.3-70b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-4-maverick` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-4-scout` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta-llama/llama-guard-3-8b` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:37:04Z | surface declaration unknown |
| `meta-llama/llama-guard-4-12b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:37:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `microsoft/phi-4` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:17:09Z | missing current evidence: usage, token_limit, context_append, streaming |
| `microsoft/phi-4-mini-instruct` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:17:09Z | surface declaration unknown |
| `microsoft/wizardlm-2-8x22b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:17:09Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:59Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2-her` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:59Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:59Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:59Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.5:free` | `text` | `openrouter.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-29T23:42:59Z | surface declaration unknown |
| `minimax/minimax-m2.7` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:59Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/codestral-2508` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/codestral-embed-2505` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `mistralai/devstral-2512` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/devstral-medium` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:38:18Z | surface declaration unknown |
| `mistralai/devstral-small` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:38:18Z | surface declaration unknown |
| `mistralai/ministral-14b-2512` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/ministral-3b-2512` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/ministral-8b-2512` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-7b-instruct-v0.1` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:38:18Z | surface declaration unknown |
| `mistralai/mistral-embed-2312` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `mistralai/mistral-large` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-large-2407` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-large-2411` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:38:18Z | surface declaration unknown |
| `mistralai/mistral-large-2512` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-medium-3` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-medium-3-5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-medium-3.1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-nemo` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-saba` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-small-24b-instruct-2501` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-small-2603` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mixtral-8x22b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/pixtral-large-2411` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:38:18Z | surface declaration unknown |
| `mistralai/voxtral-small-24b-2507` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:38:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2-0905` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2.5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2.6` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:21Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2.6:free` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:45:21Z | surface declaration unknown |
| `morph/morph-v3-fast` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:20:57Z | missing current evidence: usage, token_limit, context_append, streaming |
| `morph/morph-v3-large` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:20:57Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nex-agi/deepseek-v3.1-nex-n1` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:21:08Z | surface declaration unknown |
| `nousresearch/hermes-2-pro-llama-3-8b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:18:40Z | surface declaration unknown |
| `nousresearch/hermes-3-llama-3.1-405b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:18:40Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nousresearch/hermes-3-llama-3.1-405b:free` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:18:40Z | basic failed at provider_drift |
| `nousresearch/hermes-3-llama-3.1-70b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:18:40Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nousresearch/hermes-4-70b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:18:40Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/llama-3.3-nemotron-super-49b-v1.5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/llama-nemotron-embed-vl-1b-v2:free` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `nvidia/nemotron-3-nano-30b-a3b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-3-nano-30b-a3b:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-3-super-120b-a12b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-3-super-120b-a12b:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-nano-12b-v2-vl:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia/nemotron-nano-9b-v2:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4o-mini` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T16:17:31Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-120b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:45Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-120b:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:45Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-20b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:45Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-20b:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:45Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-oss-safeguard-20b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:45:45Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/text-embedding-3-large` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `openai/text-embedding-3-small` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `openai/text-embedding-ada-002` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `openrouter/auto` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:23:22Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openrouter/bodybuilder` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:23:22Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openrouter/free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:23:22Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openrouter/owl-alpha` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:23:22Z | surface declaration unknown |
| `openrouter/pareto-code` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:23:22Z | missing current evidence: usage, token_limit, context_append, streaming |
| `perplexity/pplx-embed-v1-0.6b` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `perplexity/pplx-embed-v1-4b` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `perplexity/sonar` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `perplexity/sonar-deep-research` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:19:52Z | basic failed at assertion |
| `perplexity/sonar-pro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `perplexity/sonar-pro-search` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `perplexity/sonar-reasoning-pro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `poolside/laguna-m.1:free` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:21:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `poolside/laguna-xs.2:free` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:21:35Z | surface declaration unknown |
| `qwen/qwen-2.5-72b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:21:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen-2.5-7b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:21:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen-2.5-coder-32b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:21:54Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen-plus` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:22:16Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen-plus-2025-07-28` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:22:16Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen-plus-2025-07-28:thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:22:16Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-14b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-235b-a22b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-235b-a22b-2507` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-235b-a22b-thinking-2507` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-30b-a3b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-30b-a3b-instruct-2507` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-30b-a3b-thinking-2507` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-32b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-8b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder-30b-a3b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder-next` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder-plus` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-embedding-4b` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `qwen/qwen3-embedding-8b` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `qwen/qwen3-max-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-next-80b-a3b-instruct:free` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:42:04Z | basic failed at provider_drift |
| `qwen/qwen3-next-80b-a3b-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-235b-a22b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-235b-a22b-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-30b-a3b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-30b-a3b-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-32b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-8b-instruct` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-8b-thinking` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-122b-a10b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-27b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-35b-a3b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-397b-a17b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-9b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-flash-02-23` | `text` | `openrouter.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:42:04Z | basic failed at provider_drift |
| `qwen/qwen3.5-plus-02-15` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-plus-20260420` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-27b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-35b-a3b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-max-preview` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-plus` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.7-max` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:42:04Z | missing current evidence: usage, token_limit, context_append, streaming |
| `rekaai/reka-edge` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:21:19Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sao10k/l3-euryale-70b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:25:35Z | surface declaration unknown |
| `sao10k/l3-lunaris-8b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:25:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sao10k/l3.1-70b-hanami-x1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:25:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sao10k/l3.1-euryale-70b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:25:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sao10k/l3.3-euryale-70b` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:25:35Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sentence-transformers/all-minilm-l12-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `sentence-transformers/all-minilm-l6-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `sentence-transformers/all-mpnet-base-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `sentence-transformers/multi-qa-mpnet-base-dot-v1` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `sentence-transformers/paraphrase-minilm-l6-v2` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `thenlper/gte-base` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `thenlper/gte-large` | `embedding` | `openrouter.embedding` | text → embedding | Best-effort | 1/3 | 2026-05-30T00:56:13Z | missing current evidence: embed_usage, embed_batch |
| `x-ai/grok-3-mini` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:19:11Z | surface declaration unknown |
| `x-ai/grok-3-mini-beta` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:19:11Z | surface declaration unknown |
| `x-ai/grok-4.20` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:11Z | missing current evidence: usage, token_limit, context_append, streaming |
| `x-ai/grok-4.20-multi-agent` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:11Z | missing current evidence: usage, token_limit, context_append, streaming |
| `x-ai/grok-4.3` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:11Z | missing current evidence: usage, token_limit, context_append, streaming |
| `x-ai/grok-build-0.1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:19:11Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2-flash` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:22:50Z | surface declaration unknown |
| `xiaomi/mimo-v2-omni` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:22:50Z | surface declaration unknown |
| `xiaomi/mimo-v2-pro` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:22:50Z | surface declaration unknown |
| `xiaomi/mimo-v2.5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:22:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2.5-pro` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:22:50Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4-32b` | `text` | `openrouter.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:44:10Z | surface declaration unknown |
| `z-ai/glm-4.5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.5-air` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.5v` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6v` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.7` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.7-flash` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5-turbo` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5.1` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5v-turbo` | `text` | `openrouter.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:44:10Z | missing current evidence: usage, token_limit, context_append, streaming |

## venice

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `aion-labs-aion-2-0` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `arcee-trinity-large-thinking` | `text` | `venice.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:55:12Z | surface declaration unknown |
| `claude-opus-4-5` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `claude-opus-4-6` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `claude-opus-4-6-fast` | `text` | `venice.chat_completions` | text → text | Experimental | 0/5 | 2026-05-29T23:55:12Z | surface declaration unknown |
| `claude-opus-4-7` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `claude-opus-4-7-fast` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `claude-sonnet-4-5` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `claude-sonnet-4-6` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek-v3.2` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek-v4-flash` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek-v4-pro` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-3-1-pro-preview` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-3-5-flash` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemini-3-flash-preview` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `gemma-4-uncensored` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google-gemma-3-27b-it` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google-gemma-4-26b-a4b-it` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google-gemma-4-31b-it` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-20` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-20-multi-agent` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-3` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-build-0-1` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `hermes-3-llama-3.1-405b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `kimi-k2-5` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `kimi-k2-6` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `llama-3.2-3b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `llama-3.3-70b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mercury-2` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax-m25` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax-m27` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistral-small-2603` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistral-small-3-2-24b-instruct` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia-nemotron-3-nano-30b-a3b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `nvidia-nemotron-cascade-2-30b-a3b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `olafangensan-glm-4.7-flash-heretic` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-4o-2024-11-20` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-4o-mini-2024-07-18` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-52` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-52-codex` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-53-codex` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-54` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-54-mini` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-54-pro` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-55` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-55-pro` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai-gpt-oss-120b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen-3-6-plus` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen-3-7-max` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-235b-a22b-instruct-2507` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-235b-a22b-thinking-2507` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-5-35b-a3b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-5-397b-a17b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-5-9b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-6-27b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-coder-480b-a35b-instruct-turbo` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-next-80b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen3-vl-235b-a22b` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `venice-uncensored-1-2` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `venice-uncensored-role-play` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai-glm-5-turbo` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai-glm-5v-turbo` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `zai-org-glm-4.6` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `zai-org-glm-4.7` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `zai-org-glm-4.7-flash` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `zai-org-glm-5` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |
| `zai-org-glm-5-1` | `text` | `venice.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:55:12Z | missing current evidence: usage, token_limit, context_append, streaming |

## xai

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `grok-2` | `text` | `xai.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:06:18Z | surface declaration unknown |
| `grok-2-1212` | `text` | `xai.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:06:18Z | surface declaration unknown |
| `grok-3` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-3-mini` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-3-mini-fast` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-3-mini-fast-latest` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-3-mini-latest` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-0709` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-1-fast-non-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-1-fast-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-fast` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-fast-non-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4-fast-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4.20-0309-non-reasoning` | `text` | `xai.chat_completions` | text → structured_object, text, tool_call | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4.20-0309-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4.20-multi-agent-0309` | `text` | `xai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:06:18Z | basic failed at provider_drift |
| `grok-4.20-non-reasoning` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4.3` | `text` | `xai.chat_completions` | text → structured_object, text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-4.3` | `text` | `xai.responses` | text → text | Experimental | 0/5 | 2026-05-29T23:12:24Z | missing or stale evidence |
| `grok-4.3` | `text` | `xai.unrecorded_text` | text → text | Best-effort | 1/5 | 2026-05-29T23:08:12Z | missing current evidence: basic, usage, token_limit, context_append |
| `grok-beta` | `text` | `xai.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T01:06:18Z | surface declaration unknown |
| `grok-build-0.1` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-code-fast-1` | `text` | `xai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T01:06:18Z | missing current evidence: usage, token_limit, context_append, streaming |
| `grok-imagine-image` | `image` | `xai.image` | text → image | First-class | 1/1 | 2026-05-30T01:06:56Z | complete current baseline |
| `grok-imagine-image-pro` | `image` | `xai.image` | text → image | First-class | 1/1 | 2026-05-30T01:06:56Z | complete current baseline |
| `grok-imagine-image-quality` | `image` | `xai.image` | text → image | First-class | 1/1 | 2026-05-30T01:06:56Z | complete current baseline |
| `grok-imagine-video` | `text` | `xai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T01:06:18Z | basic failed at provider_drift |

## zai

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `glm-4.5` | `text` | `zai.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.5-air` | `text` | `zai.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.5-flash` | `text` | `zai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:33:31Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-4.5v` | `text` | `zai.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.6` | `text` | `zai.chat_completions` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.6v` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.7` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-4.7-flash` | `text` | `zai.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T23:33:31Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-4.7-flashx` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-5` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-5-turbo` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-5.1` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |
| `glm-5v-turbo` | `text` | `zai.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-29T23:33:31Z | basic failed at provider_drift |

## zai_coder

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `glm-4.5-flash` | `text` | `zai_coder.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-29T16:28:19Z | missing current evidence: usage, token_limit, context_append, streaming |

## zai_coding_plan

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `glm-4.5-air` | `text` | `zai_coding_plan.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:11:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-4.7` | `text` | `zai_coding_plan.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:11:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-5-turbo` | `text` | `zai_coding_plan.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:11:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-5.1` | `text` | `zai_coding_plan.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:11:52Z | missing current evidence: usage, token_limit, context_append, streaming |
| `glm-5v-turbo` | `text` | `zai_coding_plan.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:11:52Z | basic failed at provider_drift |

## zenmux

| Model | Operation | Execution surface | Input → output | Tier | Baseline | Checked | Reason |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| `anthropic/claude-3.5-haiku` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `anthropic/claude-3.7-sonnet` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-haiku-4.5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `anthropic/claude-opus-4` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-opus-4.1` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-opus-4.5` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-opus-4.6` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-opus-4.7` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-opus-4.8` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `anthropic/claude-sonnet-4` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-sonnet-4.5` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `anthropic/claude-sonnet-4.6` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `baidu/ernie-5.0-thinking-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `baidu/ernie-5.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `baidu/ernie-x1.1-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-1.8` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-2.0-code` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-2.0-lite` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-2.0-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-2.0-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `bytedance/doubao-seed-code` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-chat` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-chat-v3.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-r1-0528` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-reasoner` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v3.2` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v3.2-exp` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v4-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `deepseek/deepseek-v4-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-flash-lite` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-2.5-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3-flash-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-flash-lite` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-flash-lite-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.1-pro-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemini-3.5-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `google/gemma-3-12b-it` | `text` | `zenmux.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `inclusionai/ling-1t` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ling-2.6-1t` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ling-2.6-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/llada2.1-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ring-1t` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `inclusionai/ring-2.6-1t` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `kuaishou/kat-coder-pro-v2` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta/llama-3.3-70b-instruct` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `meta/llama-4-scout-17b-16e-instruct` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2-her` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.5-lightning` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.7` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `minimax/minimax-m2.7-highspeed` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `mistralai/mistral-large-2512` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `moonshotai/kimi-k2-0905` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `moonshotai/kimi-k2-thinking` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `moonshotai/kimi-k2-thinking-turbo` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `moonshotai/kimi-k2.5` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `moonshotai/kimi-k2.6` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/chat-latest` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4` | `text` | `zenmux.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `openai/gpt-4.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4.1-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4.1-nano` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4o` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-4o-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5-chat` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5-codex` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `openai/gpt-5-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5-nano` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.1-chat` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.1-codex` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.1-codex-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.2` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.2-chat` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.2-codex` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.2-pro` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `openai/gpt-5.3-chat` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.3-codex` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.4` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.4-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.4-nano` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.4-pro` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `openai/gpt-5.5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/gpt-5.5-pro` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `openai/o1` | `text` | `zenmux.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `openai/o4-mini` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `openai/text-embedding-3-large` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `openai/text-embedding-3-small` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `qwen/qwen3-14b` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-235b-a22b-2507` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-235b-a22b-thinking-2507` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-coder-plus` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-max` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3-vl-plus` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.5-plus` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-max-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.6-plus` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `qwen/qwen3.7-max` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `sapiens-ai/agnes-1.5-flash` | `text` | `zenmux.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `sapiens-ai/agnes-1.5-lite` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `sapiens-ai/agnes-1.5-pro` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `sapiens-ai/agnes-2.0-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `stepfun/step-3` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at transport |
| `stepfun/step-3.5-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `stepfun/step-3.5-flash-free` | `text` | `zenmux.unrecorded_text` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `tencent/hunyuan-2.0-thinking` | `text` | `zenmux.chat_completions` | text → text | Experimental | 0/5 | 2026-05-30T00:10:17Z | surface declaration unknown |
| `tencent/hy3-preview` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `volcengine/doubao-seed-1.8` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `volcengine/doubao-seed-2.0-code` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `volcengine/doubao-seed-2.0-lite` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `volcengine/doubao-seed-2.0-mini` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `volcengine/doubao-seed-2.0-pro` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `volcengine/doubao-seed-code` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4-fast` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4.1-fast` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4.1-fast-non-reasoning` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4.2-fast` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `x-ai/grok-4.2-fast-non-reasoning` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `x-ai/grok-4.3` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `x-ai/grok-code-fast-1` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at provider_drift |
| `xiaomi/mimo-v2-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2-omni` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2.5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `xiaomi/mimo-v2.5-pro` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.5-air` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6v` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6v-flash` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.6v-flash-free` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.7` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-4.7-flash-free` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at transport |
| `z-ai/glm-4.7-flashx` | `text` | `zenmux.unrecorded_text` | text → text | Unsupported | 0/5 | 2026-05-30T00:10:17Z | basic failed at transport |
| `z-ai/glm-5` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5-turbo` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5.1` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |
| `z-ai/glm-5v-turbo` | `text` | `zenmux.chat_completions` | text → text | Best-effort | 1/5 | 2026-05-30T00:10:17Z | missing current evidence: usage, token_limit, context_append, streaming |

