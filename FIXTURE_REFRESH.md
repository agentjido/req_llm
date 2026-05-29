# Fixture Refresh Plan

Prepared: 2026-05-29

## Baseline

`main` is synced to `origin/main` at `6012513c` (`v1.13.0`).

Before switching to `main`, the detached HEAD at `86d0a950` was preserved on local branch `backup/detached-image-options-86d0a950`.

Commands used for this review:

```bash
git fetch origin main
git switch main
git pull --ff-only origin main
MIX_ENV=test mix mc
MIX_ENV=test mix mc --available --sample
MIX_ENV=test mix mc --available
```

Historical warning: before the fixture-tooling slice, explicit `mix mc "provider:*"` replay runs rewrote `priv/supported_models.json`. The hardened task now keeps replay checks read-only by default. Use `--update-state`, `--record`, or `--record-all` only when state should change.

## Branch Status

Current branch: `fixture-refresh-2026-06`.

Committed fixture-refresh slices:

| Commit | Scope |
| --- | --- |
| `71c75033` | Hardened fixture compatibility tooling with scenario selection, read-only replay, staged recording, strict live record semantics, scenario state, and regression tests. |
| `8a21dea6` | Expanded provider-operation tooling for image, speech, transcription, rerank, OCR, and non-text fixture entry points. |
| `84f38a47` | Hardened model operation selection so specialty models do not leak into text refreshes. |
| `74c92f75` | Refreshed Anthropic coverage, removed deprecated Claude 3-family fixtures, and normalized Anthropic fixture cookies. |
| `a4f7f64d` | Refreshed current OpenAI text coverage, removed deprecated OpenAI fixtures, and fixed OpenAI Responses/reasoning profile issues found during recording. |
| `27688e8c` | Refreshed base OpenAI non-text fixtures and hardened binary/multipart fixture replay. |

Current completed provider status:

- Anthropic is fully refreshed: 11/11 active Anthropic models pass replay.
- OpenAI current core text baselines are refreshed and replay-clean for `gpt-4o-mini`, `gpt-4o`, `gpt-4.1-mini`, `gpt-4.1`, `gpt-5-nano`, `gpt-5-mini`, `gpt-5`, and `o3`.
- OpenAI dated text aliases are refreshed and replay-clean for `gpt-4.1-2025-04-14`, `gpt-4.1-mini-2025-04-14`, `gpt-4o-2024-08-06`, `gpt-4o-2024-11-20`, `gpt-5-2025-08-07`, `gpt-5-mini-2025-08-07`, `gpt-5-nano-2025-08-07`, and `o3-2025-04-16`.
- OpenAI Pro access is confirmed and fixture-backed for `basic` on `gpt-5-pro`, `gpt-5-pro-2025-10-06`, `o3-pro`, and `o3-pro-2025-06-10`; full comprehensive Pro coverage is still an explicit decision because of cost and runtime.
- OpenAI non-text expansion reached the conservative target: fixture-file verification is 64/86 OpenAI models, with embeddings 3/3, images 5/5, speech 6/6, transcription 6/7, and text/audio-chat 44/65.
- OpenAI image generation is refreshed and replay-clean for `gpt-image-1.5`, `chatgpt-image-latest`, `gpt-image-1-mini`, `gpt-image-2`, and `gpt-image-2-2026-04-21`.
- OpenAI speech is refreshed and replay-clean for `tts-1`, `tts-1-1106`, `tts-1-hd`, `tts-1-hd-1106`, `gpt-4o-mini-tts`, and `gpt-4o-mini-tts-2025-12-15`.
- OpenAI transcription is refreshed and replay-clean for `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-03-20`, and `gpt-4o-mini-transcribe-2025-12-15`.
- OpenAI audio-chat basic fixtures are refreshed and replay-clean for `gpt-audio` and `gpt-audio-mini`. These require Chat Completions audio output defaults and transcript decoding; the dated audio-chat aliases remain a later expansion.
- Google is refreshed for the current normal text/chat target set and non-text image/embedding targets we can exercise through ReqLLM: newly replay-clean text suites include `gemini-2.5-flash-lite`, `gemini-3-flash-preview`, `gemini-3.1-flash-lite`, `gemini-3.1-pro-preview`, `gemini-3.1-pro-preview-customtools`, `gemini-3.5-flash`, and `gemini-pro-latest`; Google image generation is replay-clean for all 8 catalog image models; `gemini-embedding-001` is replay-clean for embeddings.
- Google provider-specific coverage now includes `grounding` on `gemini-3-flash-preview` and `multimodal_tool_result` retargeted from unavailable `gemini-3-pro-preview` to `gemini-3.1-pro-preview`.
- xAI current normal text targets are replay-clean for `grok-4`, `grok-4-fast`, `grok-3-mini`, `grok-3-mini-fast`, `grok-3-mini-fast-latest`, `grok-3-mini-latest`, `grok-4.20-0309-non-reasoning`, `grok-4.20-non-reasoning`, `grok-4.20-0309-reasoning`, `grok-4.3`, and `grok-build-0.1`.
- xAI current image generation is replay-clean for `grok-imagine-image` and `grok-imagine-image-quality`.
- xAI provider-specific coverage is retargeted to current models and replay-clean for web search, X search, native streaming structured output, tool-strict streaming structured output, auto streaming structured output, and truncated-stream handling.
- Deprecated OpenAI, Anthropic, Google, and xAI fixture directories have been removed from package scope.
- Minimax key and balance are no longer blocking key work. Keep Minimax as a later provider-specific fixture pass rather than retesting credentials now.

## Next Recommended Pass

1. Move to `groq` next, then `cerebras`; both already have some passing fixture state and should be cheaper to normalize than the larger aggregator providers.
2. After Groq/Cerebras, run focused passes for `zai`, `zai_coder`, and `minimax`; Minimax key/balance work is no longer blocking.
3. Then handle expansion providers by endpoint family: `fireworks_ai`, `mistral`, `cohere` rerank, `elevenlabs` speech, `zenmux`, and `venice`.
4. Keep OpenAI deferred gaps separate: dated audio-chat aliases, Pro depth, realtime, Sora, moderation, search, and legacy completions.
5. Keep Google deferred gaps separate: video/Veo, native audio/live, Lyria, robotics, deep research, `text-embedding-004` 404, and stale/unavailable `gemini-3-pro-preview`.
6. Keep xAI deferred gaps separate: `grok-2`, `grok-2-1212`, and `grok-beta` currently return 400 on normal chat; `grok-4.20-multi-agent-0309` is not a normal chat target; `grok-imagine-video` needs explicit video support before fixture recording.
7. Before broad recording, add or decide on a "currently fixture-backed passing models" selector so we can rerun the conservative set without hand-running individual specs or accidentally selecting every active LLMDB model.
8. Keep Azure, Amazon Bedrock, Alibaba, and Google Vertex out of this pass until the user explicitly reopens those credential/provider tracks.

## Current Fixture State

The fixture tree has 2309 JSON fixture files under `test/support/fixtures`.

`MIX_ENV=test mix mc` reports:

| Provider | Pass | Fail | Excluded | Untested |
| --- | ---: | ---: | ---: | ---: |
| alibaba | 0 | 0 | 0 | 50 |
| alibaba_cn | 0 | 0 | 0 | 82 |
| amazon_bedrock | 0 | 4 | 0 | 88 |
| anthropic | 11 | 0 | 0 | 0 |
| azure | 26 | 0 | 0 | 77 |
| cerebras | 3 | 0 | 0 | 2 |
| cohere | 0 | 0 | 0 | 17 |
| elevenlabs | 0 | 0 | 0 | 4 |
| fireworks_ai | 0 | 0 | 0 | 12 |
| google | 7 | 0 | 2 | 41 |
| google_vertex | 0 | 0 | 0 | 40 |
| groq | 7 | 0 | 0 | 11 |
| minimax | 6 | 0 | 0 | 0 |
| openai | 19 | 2 | 0 | 65 |
| openrouter | 45 | 0 | 0 | 319 |
| venice | 0 | 0 | 0 | 67 |
| xai | 11 | 0 | 0 | 15 |
| zai | 5 | 0 | 0 | 8 |
| zai_coder | 5 | 0 | 0 | 0 |
| zai_coding_plan | 0 | 0 | 0 | 5 |
| zenmux | 0 | 0 | 0 | 149 |

The provider sections currently sum to 165 passing, fixture-backed models after the Google and xAI pass. The task's model-level table still undercounts targeted non-text/provider-specific work because image, embedding, grounding, web-search, and streaming-structured scenarios are tracked by scenario fixtures rather than by full text-model state.

OpenAI scenario/fixture-file verification is more current than the model-level `mix mc` table because this branch records targeted scenarios without promoting every scenario result to `priv/supported_models.json`. The current OpenAI fixture-file count is 64/86:

| OpenAI operation bucket | Passing fixtures | Catalog models |
| --- | ---: | ---: |
| embedding | 3 | 3 |
| image | 5 | 5 |
| speech | 6 | 6 |
| transcription | 6 | 7 |
| text/audio-chat | 44 | 65 |

Remaining OpenAI catalog gaps are intentionally split by endpoint family: realtime (`gpt-realtime*`, `gpt-realtime-whisper`), Sora (`sora-2*`), moderation (`omni-moderation-*`), search (`gpt-5-search-api*`), legacy completions (`babbage-002`, `davinci-002`), older preview text (`gpt-4-0125-preview`, `o1-mini`), inaccessible current catalog (`gpt-5.3-codex-spark`), and deferred dated audio-chat aliases (`gpt-audio-1.5`, `gpt-audio-2025-08-28`, `gpt-audio-mini-2025-12-15`).

Google scenario/fixture-file verification is more current than the model-level `mix mc` table. Current non-deprecated fixture-file coverage is 22/49 by catalog directory, with the normal chat targets and all current Google image models covered. Known Google gaps are endpoint-specific or unavailable through the current provider path: native audio/live, Veo/video, Lyria, robotics, deep research, `text-embedding-004` 404, legacy Gemini 1.5 404s, and `gemini-3-pro-preview` 404.

xAI scenario/fixture-file verification is also more current than the model-level `mix mc` table. Current non-deprecated fixture-file coverage is 13/18: text 11/16 and image 2/2. Known xAI gaps are `grok-2`, `grok-2-1212`, and `grok-beta` returning 400 on normal chat, `grok-4.20-multi-agent-0309` requiring separate multi-agent handling, and `grok-imagine-video` requiring video-operation support.

## Date Findings

Most passing fixture state is old relative to 2026-05-29:

| Age bucket from `priv/supported_models.json` pass entries | Count |
| --- | ---: |
| 180 days or older | 153 |
| 120-179 days | 9 |
| 30-89 days | 0 |
| Less than 30 days | 7 |

Oldest passing state entries:

| Model | Last checked | Age |
| --- | --- | ---: |
| `openai:text-embedding-ada-002` | 2025-10-04 | 236 days |
| `openai:text-embedding-3-small` | 2025-10-04 | 236 days |
| `openai:text-embedding-3-large` | 2025-10-04 | 236 days |
| `google:gemini-embedding-001` | 2025-10-04 | 236 days |
| most `xai`, `zai`, `zai_coder`, and many `openrouter` passes | 2025-11-14 | 195 days |

Fixture file mtimes show the oldest fixture files from 2025-10-07. The newest recent fixture batches are mostly:

| Provider | Newest fixture date |
| --- | --- |
| anthropic | 2026-05-28 |
| fireworks_ai | 2026-05-20 |
| google | 2026-05-20 |
| minimax | 2026-05-05 |
| google_vertex | 2026-05-01 |
| openai | 2026-05-29 |
| xai | 2026-04-26 |

This is stale enough that the refresh should start with a small live smoke test before broad recording.

## API Key Preflight

Credential status is based on direct `curl` checks after sourcing the repo-local `.env` file, unless noted otherwise. The active refresh scope intentionally ignores Azure and Amazon Bedrock for now.

| Provider area | Env vars | Current status |
| --- | --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` | verified OK |
| OpenAI | `OPENAI_API_KEY` | verified OK |
| Google AI Studio | `GOOGLE_API_KEY` | verified OK |
| Groq | `GROQ_API_KEY` | verified OK |
| OpenRouter | `OPENROUTER_API_KEY` | verified OK |
| xAI | `XAI_API_KEY` | verified OK |
| Cerebras | `CEREBRAS_API_KEY` | verified OK, including a minimal chat call |
| Z.ai | `ZAI_API_KEY` | verified OK, including a minimal chat call |
| Z.ai coder | `ZAI_API_KEY` | same verified key; provider-specific fixture smoke still needed |
| Zenmux | `ZENMUX_API_KEY` | verified OK |
| Venice | `VENICE_API_KEY` | verified OK |
| DeepSeek | `DEEPSEEK_API_KEY` | verified OK; no current LLMDB models in this checkout |
| ElevenLabs | `ELEVENLABS_API_KEY` | verified OK for user, models, voices, and minimal TTS |
| Fireworks | `FIREWORKS_API_KEY` | verified OK, including a minimal chat call |
| Cohere | `COHERE_API_KEY` | verified OK with a minimal rerank call |
| Mistral | `MISTRAL_API_KEY` | verified OK, including a minimal chat call |
| Amazon Bedrock | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` or `AWS_DEFAULT_REGION`; alternatively `AWS_BEARER_TOKEN_BEDROCK` | out of scope this pass |
| Azure | `AZURE_API_KEY` + `AZURE_BASE_URL`, or family-specific key/base URL pairs | out of scope this pass |
| Minimax | `MINIMAX_API_KEY` | auth verified OK on models endpoint; balance has been updated; no further key retest needed before its provider pass |
| Alibaba | `DASHSCOPE_API_KEY` | missing |
| Google Vertex | `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT` | missing |

Active credential decision:

1. No key work is required for the in-scope text fixture refresh.
2. Ignore Azure and Amazon Bedrock for this pass.
3. Keep Alibaba and Google Vertex as optional future expansion.

## Mix Task Notes

Useful commands:

```bash
MIX_ENV=test mix mc
MIX_ENV=test mix mc --available
MIX_ENV=test mix mc --available --sample
MIX_ENV=test mix mc --sample --record
MIX_ENV=test mix mc "openai:gpt-4o-mini" --record
MIX_ENV=test mix mc "openai:*" --record
MIX_ENV=test mix mc "google:*" --type embedding --record
MIX_ENV=test mix mc "anthropic:claude-haiku-4-5" --scenario basic
MIX_ENV=test mix mc "anthropic:claude-haiku-4-5" --scenario basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4o-mini" --capability core
MIX_ENV=test mix mc "openai:gpt-4o-mini" --scenario basic --update-state
MIX_ENV=test mix mc "openai:gpt-image-1.5" --type image --scenario image_basic
MIX_ENV=test mix mc "openai:tts-1" --type speech --scenario speech_basic --record
MIX_ENV=test mix mc "openai:whisper-1" --type transcription --scenario transcription_basic --record
MIX_ENV=test mix mc "cohere:rerank-v3.5" --type rerank --scenario rerank_basic --record
```

Important behavior:

- `mix mc` with no spec prints current coverage and does not run tests.
- `mix mc --available` lists registry models and does not run tests.
- `mix mc --sample` runs tests for configured sample models.
- `mix mc "provider:*" --record` records every current registry model for that implemented provider, not just models with existing fixtures.
- `--type text` is the default.
- Use `--type embedding|image|speech|transcription|rerank|ocr` for non-text fixture refresh.
- `--record` and `--record-all` both make live API calls for selected specs in the current task implementation.
- Replay checks are read-only by default.
- Use `--scenario` for one or more comma-separated scenario tags.
- Use `--capability core|conversation|streaming|tools|objects|reasoning|embedding|image|speech|transcription|rerank|ocr` for scenario groups.
- Use `--update-state` when a replay run should write scenario or model state.
- Record mode defaults to `--max-concurrency 1`; replay mode uses higher concurrency unless overridden.
- Record mode writes fixtures into a temporary staging directory and promotes them only after the child ExUnit run passes.
- Scenario run state is written to `priv/model_compat_scenarios.json`; full model state remains in `priv/supported_models.json`.

`MIX_ENV=test mix mc --available --sample` currently reports the exact sample list as:

| Provider | Sample model |
| --- | --- |
| anthropic | `claude-3-5-haiku-20241022` |
| google | `gemini-2.0-flash` |
| openai | `gpt-4o-mini` |

`MIX_ENV=test mix mc --sample` resolves `anthropic:claude-haiku-4-5` as an additional sample model and currently fails in replay mode. That is expected during this prep: state says those sample fixtures pass, but the current comprehensive test set now expects fixture names such as `context_append_1` that are missing for some models. The first live recording pass should refresh these sample fixtures.

## Fixture System Evaluation

Recommendation: review and refresh the model compatibility task and fixture system before broad fixture recording.

Evidence from this branch:

1. `lib/mix/tasks/model_compat.ex` was last changed on 2025-11-29, before most of the recent provider and capability growth.
2. `test/support/model_matrix.ex` and `test/support/fixtures.ex` were last changed on 2025-11-16.
3. `test/AGENTS.md` was last changed on 2025-10-13 and no longer fully describes the comprehensive scenario set.
4. Since then, ReqLLM has added or substantially changed Azure, Google Vertex, Amazon Bedrock, OpenAI Responses routing, response assembly, reasoning signatures, MiniMax, Fireworks, and other provider paths.
5. `test/support/fixture.ex` still has a hand-written provider module mapping for streaming replay; it omits newer providers such as `zai`, `zai_coder`, `minimax`, `fireworks_ai`, `venice`, `zenmux`, `mistral`, and `deepseek`.
6. The current `mix mc` flow runs whole-model comprehensive tests, writes model-level state, and has no scenario/capability selector even though the tests already have semantic scenario tags.

Decision: the first PR on this branch should be a fixture-system/tooling PR, not a large fixture-data PR.

Proposed branch-level PR sequence:

1. Fixture tooling PR: add scenario/capability selection, scenario-level state, updated docs, provider registry-based replay dispatch, and safer record/replay reporting.
2. Core fixture refresh PRs: record and replay-validate `basic`, `usage`, and `token_limit` by provider.
3. Capability fixture refresh PRs: streaming, context, tools, objects, and reasoning in separate focused batches.
4. Expansion provider PRs: Fireworks, Mistral, Zenmux, Venice, ElevenLabs, Cohere, and DeepSeek only after the core compatibility contract is clean.

## Fixture Runner Review Findings

Review date: 2026-05-29

Original validation run:

```bash
MIX_ENV=test mix test test/req_llm/test/vcr_test.exs test/req_llm/test/transcript_test.exs test/req_llm/test/chunk_collector_test.exs test/req_llm/streaming/fixtures_test.exs test/req_llm/stream_server/fixture_capture_test.exs
```

Result: 65 tests, 0 failures.

Findings:

1. Replay checks are not read-only. `mix mc "provider:model"` calls `save_state/2` in replay mode and rewrites `priv/supported_models.json`. The check path and record path need separate state behavior. Default fixture checks should be read-only unless an explicit `--update-state` or `--record` flag is used.
2. Record mode overwrites fixture files before the scenario has proven successful. Non-streaming capture inserts the save step before response decoding, and streaming capture saves during stream finalization before later assertions complete. Failed live scenarios can therefore leave rewritten fixture files. The runner should record to a temp/quarantine path and promote only after the ExUnit scenario passes.
3. Fixture save failures do not fail the recording run. `VCR.record/2` errors are logged but not propagated, and streaming save errors are warnings. A fixture refresh task must treat save failure as scenario failure.
4. Credential fallback is unsafe for fixture refresh. Record mode can fall back to an existing fixture when credentials are missing, which can make a live re-record command pass without hitting the provider. Refresh mode should be strict-live by default and require an explicit fallback flag for development convenience.
5. The VCR transcript loader still derives provider/model from URLs for the current non-event fixture formats. Newer providers such as Z.ai and Minimax load as `:unknown`, for example `zai/glm_4_6/basic.json` loads as `{:unknown, "unknown:glm-4.6"}`. The loader should prefer explicit fixture metadata when present and use provider registry data instead of URL heuristics.
6. Streaming replay dispatch is hand-maintained. `ReqLLM.Step.Fixture.Backend` has a private provider-module map that omits newer providers. It should use `ReqLLM.Providers.get/1`.
7. Streaming fixture detection is inferred from the number of data events. A one-chunk streaming response is treated as non-streaming. The transcript format should carry an explicit `streaming` or `transport` field.
8. `mix mc` has no scenario or capability selector. It can only run the whole comprehensive text suite or embedding suite. This is the root reason one advanced failure can mark a model failed and dirty several fixture files.
9. `priv/supported_models.json` only stores model-level status and timestamp. It does not store scenario status, fixture names, error classes, or whether the latest run was replay or live record.
10. Record concurrency uses `System.schedulers_online() * 2`, the same as replay. Live refresh should default to conservative concurrency, probably 1 per provider, with an explicit `--max-concurrency` override.
11. Alias handling is inconsistent. Model selection resolves aliases for registry existence but keeps the original model id in result/state keys. This can create state entries under aliases while fixture paths use canonical model ids.
12. There are unit tests for VCR, transcripts, chunk collection, and streaming fixture helpers, but no direct tests around `Mix.Tasks.ReqLlm.ModelCompat` selection, state writes, scenario filtering, record/replay mode semantics, or failure reporting.

Recommended first implementation slice:

1. Make `mix mc` replay/check read-only by default.
2. Add `--scenario` support that maps directly to ExUnit `scenario` tags.
3. Add `--capability core|conversation|streaming|tools|objects|reasoning|embedding` as scenario groups.
4. Add `--max-concurrency`, with record mode defaulting lower than replay mode.
5. Add strict record semantics: no credential fallback, no silent save failures, and no promotion of fixtures unless the scenario passed.
6. Replace hand-maintained provider lookup and URL provider derivation with registry-backed provider resolution.
7. Add scenario-level state, keeping whole-model status as a computed summary.
8. Add task-level tests for model selection, alias canonicalization, state behavior, scenario args, and record failure propagation.

Implemented tooling slice:

1. Added `--scenario`, `--capability`, `--max-concurrency`, and `--update-state`.
2. Made replay/check runs read-only by default.
3. Added staged live recording with promotion only after a passing child ExUnit run.
4. Disabled credential fallback during model-compat recording.
5. Made fixture save failures fail the run instead of logging and continuing.
6. Switched streaming replay provider lookup to `ReqLLM.Providers.get!/1`.
7. Added explicit streaming metadata and response-header sanitization to transcripts.
8. Added scenario-level state in `priv/model_compat_scenarios.json`.
9. Added task-level and transcript regression tests.

Implemented provider-operation expansion:

1. Added a shared `ReqLLM.ModelOperation` classifier for `text`, `embedding`, `image`, `speech`, `transcription`, `rerank`, `ocr`, and `all`.
2. Updated `ModelMatrix` and `mix mc` so operation selection is registry/capability aware for specialty model families, not just text versus embedding.
3. Added `sample_image_models`, `sample_speech_models`, `sample_transcription_models`, `sample_rerank_models`, and `sample_ocr_models` test config entries.
4. Replaced hand-written OpenAI and Google image coverage tests with `ReqLLM.ProviderTest.ImageGeneration`.
5. Added provider coverage macros for image generation, text-to-speech, transcription, rerank, and OCR.
6. Added coverage entry points for `xai` image generation, `openai` and `elevenlabs` speech, `openai` and `groq` transcription, and `cohere` rerank.
7. Added a deterministic local WAV sample at `test/support/audio/hello_world.wav` for transcription fixture recording.
8. Made `ReqLLM.Step.Fixture.maybe_attach/3` store the resolved model in request private data so non-chat APIs can use the same fixture backend as chat and image requests.

## Recommended Refresh Sequence

### Phase 0: Key and Smoke Test

1. Run a live sample refresh for the configured text sample models:

```bash
MIX_ENV=test mix mc --sample --record
```

2. Do not run the configured embedding sample command for this pass because the configured embedding sample set includes Azure and Amazon Bedrock. Run only explicit in-scope embedding models if embeddings are part of this refresh:

```bash
MIX_ENV=test mix mc "openai:text-embedding-3-small" --type embedding --record
MIX_ENV=test mix mc "openai:text-embedding-3-large" --type embedding --record
MIX_ENV=test mix mc "openai:text-embedding-ada-002" --type embedding --record
MIX_ENV=test mix mc "google:gemini-embedding-001" --type embedding --record
MIX_ENV=test mix mc "google:text-embedding-004" --type embedding --record
```

3. If a key is stale, stop at the first provider failure and fix that key before continuing. Avoid mixing credential failures with model compatibility failures.

### Phase 1: Refresh Current Passing Coverage

Conservative candidate target: re-record the 117 in-scope passing, fixture-backed, current-registry models listed below. This excludes Azure and Amazon Bedrock by scope. Anthropic, current OpenAI core text, and selected OpenAI dated text aliases are already refreshed on this branch. Minimax stays in the candidate list after the balance update, but should be refreshed in its own small provider pass. Amazon Bedrock stays out of triage for this pass.

For one model:

```bash
MIX_ENV=test mix mc "openai:gpt-4o-mini" --record
```

For broad provider recording, only use this after deciding that new untested registry models should be attempted too:

```bash
MIX_ENV=test mix mc "openai:*" --record
```

Recommended provider order:

1. `google`, `groq`, `openrouter`, `xai`, `cerebras`: next highest-value text providers with keys present; expect provider-specific model drift.
2. `zai`, `zai_coder`: key is verified and the basic fixture path now works; run as provider-specific passes.
3. `minimax`: key and balance are verified; run as a small provider pass rather than mixing it into a broad core batch.
4. `fireworks_ai`, `zenmux`, `venice`: keys are verified; treat as expansion providers because they have no passing fixture-backed models in the current conservative list.
5. `elevenlabs`: key and TTS are verified, but it is speech/TTS coverage, not normal text `mix mc` coverage.
6. `deepseek`: key is verified, but this checkout currently has no LLMDB models for the `deepseek` provider.
7. `cohere`: key is verified, but this provider is rerank-only in ReqLLM.
8. `mistral`: key is verified; treat as an expansion provider because it has no passing fixture-backed models in the current conservative list.

### Phase 2: Triage Current Failing Fixture-Backed Models

Current failing fixture-backed models:

| Provider | Models |
| --- | --- |
| amazon_bedrock | `anthropic.claude-haiku-4-5-20251001-v1:0`, `anthropic.claude-opus-4-1-20250805-v1:0`, `anthropic.claude-sonnet-4-5-20250929-v1:0`, `meta.llama3-3-70b-instruct-v1:0` |
| openai | `gpt-5-pro`, `o3-pro` |

Skip the Amazon Bedrock failures for this pass. For OpenAI pro models, current account access and routing now work for `basic` on canonical and dated Pro ids, but full comprehensive coverage has not been recorded yet. Keep `gpt-5-pro`, `gpt-5-pro-2025-10-06`, `o3-pro`, and `o3-pro-2025-06-10` as focused follow-up items rather than treating their whole-model status as resolved.

### Phase 3: Expand Beyond Existing Fixtures

After the current passing set is refreshed and replay-clean, decide whether to expand coverage into untested registry models. Use provider-scoped commands and expect many new failures from access tiers, retired models, unsupported modalities, or provider catalog drift.

Examples:

```bash
MIX_ENV=test mix mc "anthropic:*" --record
MIX_ENV=test mix mc "openai:*" --record
MIX_ENV=test mix mc "openrouter:*" --record
MIX_ENV=test mix mc "xai:*" --record
MIX_ENV=test mix mc "*:*" --type embedding --record
```

## Branch Run Log

Branch: `fixture-refresh-2026-06`

Initial commands:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc --sample --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "minimax:MiniMax-M2.1" --record
MIX_ENV=test mix mc "openai:gpt-4o-mini"
MIX_ENV=test mix mc "anthropic:claude-haiku-4-5"
```

Results:

| Command | Result |
| --- | --- |
| `mix mc --sample --record` | 2/4 passing: `anthropic:claude-haiku-4-5` and `openai:gpt-4o-mini` passed; `anthropic:claude-3-5-haiku-20241022` and `google:gemini-2.0-flash` failed |
| `mix mc "minimax:MiniMax-M2.1" --record` | failed with provider `429` |
| `mix mc "openai:gpt-4o-mini"` | replay passed |
| `mix mc "anthropic:claude-haiku-4-5"` | replay command exited successfully |

10-model process check:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4.1-nano" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-nano" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-haiku-20240307" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-sonnet-4-20250514" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "groq:llama-3.1-8b-instant" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "groq:openai/gpt-oss-20b" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "cerebras:gpt-oss-120b" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "xai:grok-3-mini" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "zai:glm-4.5-flash" --record
set -a && source ./.env && set +a && MIX_ENV=test mix mc "zai_coder:glm-4.5-flash" --record
```

| Model | Result | Main failure signal |
| --- | --- | --- |
| `openai:gpt-4.1-nano` | failed | stream API error after writing 10 fixture files; model is deprecated and points to `gpt-5-nano` |
| `openai:gpt-5-nano` | failed | `NimbleOptions.ValidationError` in object streaming |
| `anthropic:claude-3-haiku-20240307` | failed | request API error after writing 10 fixture files |
| `anthropic:claude-sonnet-4-20250514` | failed | stream API error after writing object fixtures |
| `groq:llama-3.1-8b-instant` | failed | provider `413` request error during tool round trip |
| `groq:openai/gpt-oss-20b` | failed | `NimbleOptions.ValidationError` |
| `cerebras:gpt-oss-120b` | failed | `ArgumentError` |
| `xai:grok-3-mini` | failed | `ArgumentError` after usage and streaming fixtures |
| `zai:glm-4.5-flash` | passed | full model run passed |
| `zai_coder:glm-4.5-flash` | failed | request API error after writing 9 fixture files |

Process readout:

1. Whole-model `--record` is too noisy for the next batch. A single unsupported capability can mark the model failed after several live fixture files have already been rewritten.
2. The next refresh pass should be scenario-first: record basic text, no-tool, usage, and token-limit fixtures across a small provider set before attempting streaming, object, tool, context, or reasoning scenarios.
3. Keep failed partial writes out of fixture refresh commits unless the failure fixture itself is intentional and replay-clean.
4. Prefer small provider/scenario commits after replay validation, starting with the known passing model runs: `openai:gpt-4o-mini`, `anthropic:claude-haiku-4-5`, and `zai:glm-4.5-flash`.

Current caution: the failed live runs wrote partial fixture updates for the failing models and updated `priv/supported_models.json` failure state. Review or discard those diffs before staging fixture changes.

Tooling slice smoke:

```bash
MIX_ENV=test mix compile
MIX_ENV=test mix test test/mix/tasks/model_compat_test.exs test/req_llm/test/vcr_test.exs test/req_llm/test/transcript_test.exs test/req_llm/test/chunk_collector_test.exs test/req_llm/streaming/fixtures_test.exs test/req_llm/stream_server/fixture_capture_test.exs
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-haiku-4-5" --scenario basic --record --max-concurrency 1 --debug
MIX_ENV=test mix mc "anthropic:claude-haiku-4-5" --scenario basic --max-concurrency 1 --debug
```

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix compile` | passed |
| focused regression suite | 74 tests, 0 failures |
| Claude Haiku `basic` live record | 1 test, 0 failures, promoted `basic` |
| Claude Haiku `basic` replay | 1 test, 0 failures |

The smoke updated `test/support/fixtures/anthropic/claude_haiku_4_5_20251001/basic.json` and added `priv/model_compat_scenarios.json` with `anthropic:claude-haiku-4-5-20251001` / `basic` passing in record mode.

Provider-operation tooling smoke:

```bash
MIX_ENV=test mix compile
MIX_ENV=test mix test test/req_llm/model_operation_test.exs test/mix/tasks/model_compat_test.exs test/req_llm/test/model_matrix_test.exs
MIX_ENV=test mix test --include coverage --only "scenario:image_basic" test/coverage/openai/image_generation_test.exs test/coverage/google/image_generation_test.exs
MIX_ENV=test mix test test/coverage/xai/image_generation_test.exs test/coverage/openai/speech_test.exs test/coverage/elevenlabs/speech_test.exs test/coverage/openai/transcription_test.exs test/coverage/groq/transcription_test.exs test/coverage/cohere/rerank_test.exs
MIX_ENV=test mix mc "openai:gpt-image-1.5" --type image --scenario image_basic --max-concurrency 1
```

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix compile` | passed |
| operation/model-matrix regression suite | 44 tests, 0 failures |
| existing OpenAI and Google image fixture replay | 2 tests, 0 failures |
| specialty coverage file load check | 0 tests, 0 failures, 5 excluded |
| OpenAI image `mix mc` replay | 1/1 active models passing |

Hardening note: operation parsing now rejects unknown `--type` values explicitly, avoids creating atoms from arbitrary operation strings, and keeps specialty-shaped models out of text coverage even when their provider-specific specialty suite is not enabled yet.

Scenario-first live smoke:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-haiku-4-5-20251001" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o-mini" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "google:gemini-2.0-flash" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "groq:llama-3.1-8b-instant" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openrouter:openai/gpt-4o-mini" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "xai:grok-3-mini" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "cerebras:gpt-oss-120b" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "zai:glm-4.5-flash" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "fireworks_ai:accounts/fireworks/models/gpt-oss-20b" --scenario basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "cohere:rerank-v3.5" --type rerank --scenario rerank_basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "zai_coder:glm-4.5-flash" --scenario basic --record --max-concurrency 1
```

| Model | Operation | Record result | Replay result |
| --- | --- | --- | --- |
| `anthropic:claude-haiku-4-5-20251001` | text/basic | passed | passed |
| `openai:gpt-4o-mini` | text/basic | passed | passed |
| `google:gemini-2.0-flash` | text/basic | passed | passed |
| `groq:llama-3.1-8b-instant` | text/basic | passed | passed |
| `openrouter:openai/gpt-4o-mini` | text/basic | passed | passed |
| `xai:grok-3-mini` | text/basic | passed | passed |
| `cerebras:gpt-oss-120b` | text/basic | passed | passed |
| `zai:glm-4.5-flash` | text/basic | passed | passed |
| `fireworks_ai:accounts/fireworks/models/gpt-oss-20b` | text/basic | passed | passed |
| `cohere:rerank-v3.5` | rerank/rerank_basic | passed | passed |
| `zai_coder:glm-4.5-flash` | text/basic | passed after base URL fix | passed |

Additional failed record attempts:

| Model | Scenario | Failure signal | Fixture promotion |
| --- | --- | --- | --- |
| `minimax:MiniMax-M2.1` | `basic` | provider `429` | not promoted |

The original `zai_coder:glm-4.5-flash` attempt failed with `non-existing domain` because LLMDB provider metadata supplied `https://api.zai.chat`, which did not resolve locally and shadowed ReqLLM's working coding endpoint default. The provider fix forces the Z.ai module default unless a caller or app config explicitly overrides `base_url`; after that change, Z.ai Coder recorded and replayed cleanly.

The live record path promoted one fixture for each passing scenario, and the immediate replay path passed for the same 11 successful scenarios. `priv/model_compat_scenarios.json` records the passing scenario statuses and the remaining MiniMax failed record attempt.

Single-model deep comprehensive smoke:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-haiku-4-5-20251001" --record --max-concurrency 1
MIX_ENV=test mix mc "anthropic:claude-haiku-4-5-20251001" --max-concurrency 1
```

| Model | Record result | Replay result | Fixtures promoted |
| --- | --- | --- | ---: |
| `anthropic:claude-haiku-4-5-20251001` | passed | passed | 14 |

The full comprehensive record covered `basic`, `streaming`, `token_limit`, `usage`, `context_append_1`, `context_append_2`, `multi_tool`, `tool_round_trip_1`, `tool_round_trip_2`, `no_tool`, `object_basic`, `object_streaming`, `reasoning_basic`, and `reasoning_streaming`. `priv/supported_models.json` now marks the canonical model as passing with `last_checked` `2026-05-29T16:30:53Z`.

Anthropic provider cleanup:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-5-haiku-20241022" --capability core --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-haiku-20240307" --capability core --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-5-sonnet-20240620" --capability core --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-7-sonnet-20250219" --capability core --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-3-sonnet-20240229" --capability core --record --max-concurrency 1
```

| Model | Result | Decision |
| --- | --- | --- |
| `anthropic:claude-3-5-haiku-20241022` | provider `404` | removed Claude 3-family fixtures and denied from package candidates |
| `anthropic:claude-3-haiku-20240307` | provider `404` | removed Claude 3-family fixtures and denied from package candidates |
| `anthropic:claude-3-5-sonnet-20240620` | provider `404` | removed Claude 3-family state entries and denied from package candidates |
| `anthropic:claude-3-7-sonnet-20250219` | provider `404`; registry marks deprecated with replacement `claude-sonnet-4-5-20250929` | removed Claude 3-family fixtures/state and denied from package candidates |
| `anthropic:claude-3-sonnet-20240229` | provider `404` | removed Claude 3-family state entries and denied from package candidates |

Cleanup removed the tracked fixture directories for `anthropic/claude_3_5_haiku_20241022`, `anthropic/claude_3_5_haiku_latest`, `anthropic/claude_3_7_sonnet_latest`, and `anthropic/claude_3_haiku_20240307`, deleted Claude 3-family generated state entries, and changed the Anthropic LLMDB deny filter to `claude-3-*` and `claude-3.*`.

Additional Claude 4-family refresh:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "anthropic:claude-opus-4-5" --capability core --record --max-concurrency 1
MIX_ENV=test mix mc "anthropic:claude-opus-4-5" --capability core --max-concurrency 1
```

`anthropic:claude-opus-4-5` recorded and replayed `basic`, `usage`, and `token_limit` successfully. The subsequent Anthropic pass recorded full comprehensive fixtures, or the supported comprehensive subset where structured output is not available, for the remaining Claude 4-family models that lacked current coverage.

| Model | Live record result | Replay result | Notes |
| --- | --- | --- | --- |
| `anthropic:claude-opus-4-5` | passed | passed | 14 fixtures |
| `anthropic:claude-opus-4-5-20251101` | passed | passed | 14 fixtures |
| `anthropic:claude-opus-4-6` | passed | passed | 14 fixtures |
| `anthropic:claude-opus-4-7` | passed | passed | 14 fixtures |
| `anthropic:claude-sonnet-4-6` | passed | passed | 14 fixtures |
| `anthropic:claude-opus-4-1-20250805` | passed | passed | 14 fixtures |
| `anthropic:claude-opus-4-20250514` | passed | passed | 12 fixtures; object scenarios skipped because Anthropic reports structured outputs unsupported |
| `anthropic:claude-sonnet-4-20250514` | passed | passed | 12 fixtures; object scenarios skipped because Anthropic reports structured outputs unsupported |
| `anthropic:claude-sonnet-4-5-20250929` | passed | passed | 14 fixtures |

The comprehensive macro now requires Anthropic `extra.capabilities.structured_outputs.supported` to be true before enabling `object_basic` or `object_streaming`. That avoids the provider `400` response observed for `claude-opus-4-20250514` and `claude-sonnet-4-20250514`.

Final Anthropic replay:

```bash
MIX_ENV=test mix mc "anthropic:*" --max-concurrency 4
```

Result: 11/11 active Anthropic models passing, 0 failing, 0 untested.

Fixture hygiene note: live and legacy Anthropic fixtures were scanned for raw cookie values after recording. Any `set-cookie` values under `test/support/fixtures/anthropic` are now normalized to `[REDACTED:set-cookie]`.

OpenAI focused refresh:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4o" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4.1-mini" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1-mini" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4.1" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-nano" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-nano" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-mini" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-mini" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:o3" --record --max-concurrency 1
MIX_ENV=test mix mc "openai:o3" --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-pro" --scenario basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-pro" --scenario basic --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:o3-pro" --scenario basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:o3-pro" --scenario basic --max-concurrency 1
```

| Model | Record result | Replay result | Fixtures promoted |
| --- | --- | --- | ---: |
| `openai:gpt-4o-mini` | passed | passed | 12 |
| `openai:gpt-4o` | passed | passed | 12 |
| `openai:gpt-4.1-mini` | passed after Responses include fix | passed | 12 |
| `openai:gpt-4.1` | passed | passed | 12 |
| `openai:gpt-5-nano` | passed after streaming reasoning option fix | passed | 14 |
| `openai:gpt-5-mini` | passed | passed | 14 |
| `openai:gpt-5` | passed | passed | 14 |
| `openai:o3` | passed | passed | 14 |
| `openai:gpt-5-pro` | `basic` passed after high-effort fix | `basic` passed | 1 |
| `openai:o3-pro` | `basic` passed | `basic` passed | 1 |

OpenAI implementation findings from this pass:

1. `gpt-4.1` and `gpt-4.1-mini` use the Responses API but do not support `include: ["reasoning.encrypted_content"]`. ReqLLM now routes them through Responses without treating them as reasoning models.
2. Streaming fixture paths can re-enter option validation with already-translated reasoning effort strings. OpenAI now normalizes those strings before validation.
3. `gpt-5-pro` only accepts `reasoning.effort: "high"`. OpenAI parameter profiles now default and fix GPT-5 Pro reasoning effort to high.
4. A broad `mix mc "openai:*"` replay is still a discovery command, not a gate: it expands to many untested active registry models and is too broad for fixture refresh commits.
5. Deprecated OpenAI fixtures were removed for `codex_mini_latest`, `gpt_3_5_turbo`, `gpt_4`, `gpt_4_turbo`, `gpt_4_1_nano`, `gpt_4o_2024_05_13`, `gpt_5_chat_latest`, `gpt_5_codex`, `gpt_image_1`, `o1`, `o3_mini`, and `o4_mini`.

OpenAI follow-up:

1. Decide whether Pro models should get full comprehensive suites in this branch or remain basic-probe coverage because of cost and runtime.
2. Decide whether the basic-probed future/current GPT-5.1+ families should get full comprehensive suites now.
3. Refresh OpenAI embedding, image, speech, and transcription fixtures with `--type`-specific commands rather than mixing them into text coverage.

OpenAI text expansion pass:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4.1-2025-04-14" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4.1-mini-2025-04-14" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o-2024-08-06" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o-2024-11-20" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-2025-08-07" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-mini-2025-08-07" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-5-nano-2025-08-07" --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:o3-2025-04-16" --record --max-concurrency 1
```

| Model | Record result | Replay result | Fixtures promoted |
| --- | --- | --- | ---: |
| `openai:gpt-4.1-2025-04-14` | passed | passed | 6 |
| `openai:gpt-4.1-mini-2025-04-14` | passed | passed | 6 |
| `openai:gpt-4o-2024-08-06` | passed | passed | 12 |
| `openai:gpt-4o-2024-11-20` | passed | passed | 12 |
| `openai:gpt-5-2025-08-07` | passed after fixture helper token-floor fix | passed | 7 |
| `openai:gpt-5-mini-2025-08-07` | passed after fixture helper token-floor fix | passed | 7 |
| `openai:gpt-5-nano-2025-08-07` | passed after fixture helper token-floor fix | passed | 7 |
| `openai:o3-2025-04-16` | passed | passed | 6 |

The dated GPT-5 aliases exposed an LLMDB metadata mismatch: their `capabilities.reasoning.enabled` value is false, but `extra.constraints.reasoning_effort` is `required`. The comprehensive streaming scenario initially sent only the creative bundle's `max_tokens: 100`; OpenAI returned `response.incomplete` before emitting text. `ReqLLM.Test.Helpers.reasoning_overlay/3` now treats required reasoning metadata as reasoning-control metadata, applies the requested token floor, and preserves an explicit `reasoning_effort` when the caller supplies one.

Basic-only OpenAI access probes that recorded and replayed cleanly:

- `openai:gpt-5-pro`
- `openai:gpt-5-pro-2025-10-06`
- `openai:o3-pro`
- `openai:o3-pro-2025-06-10`
- `openai:gpt-5.1`
- `openai:gpt-5.1-2025-11-13`
- `openai:gpt-5.2`
- `openai:gpt-5.2-2025-12-11`
- `openai:gpt-5.2-chat-latest`
- `openai:gpt-5.2-pro`
- `openai:gpt-5.2-pro-2025-12-11`
- `openai:gpt-5.3-chat-latest`
- `openai:gpt-5.3-codex`
- `openai:gpt-5.4`
- `openai:gpt-5.4-2026-03-05`
- `openai:gpt-5.4-mini`
- `openai:gpt-5.4-mini-2026-03-17`
- `openai:gpt-5.4-nano`
- `openai:gpt-5.4-nano-2026-03-17`
- `openai:gpt-5.4-pro`
- `openai:gpt-5.4-pro-2026-03-05`
- `openai:gpt-5.5`
- `openai:gpt-5.5-2026-04-23`
- `openai:gpt-5.5-pro`
- `openai:gpt-5.5-pro-2026-04-23`

OpenAI text-shaped registry entries that failed the `basic` live probe:

| Model | Failure signal |
| --- | --- |
| `openai:babbage-002` | provider `404` |
| `openai:davinci-002` | provider `404` |
| `openai:chat-latest` | provider `400` |
| `openai:gpt-4-0125-preview` | provider `404` |
| `openai:gpt-5.3-codex-spark` | provider `400` |
| `openai:gpt-5-search-api` | provider `400` |
| `openai:gpt-5-search-api-2025-10-14` | provider `400` |

OpenAI replay gate after the text expansion pass:

```bash
MIX_ENV=test mix mc "openai:gpt-4o-mini" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4o" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1-mini" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-nano" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-mini" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5" --max-concurrency 1
MIX_ENV=test mix mc "openai:o3" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1-2025-04-14" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4.1-mini-2025-04-14" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4o-2024-08-06" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-4o-2024-11-20" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-2025-08-07" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-mini-2025-08-07" --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-5-nano-2025-08-07" --max-concurrency 1
MIX_ENV=test mix mc "openai:o3-2025-04-16" --max-concurrency 1
```

Result: 16/16 replay-clean full-suite OpenAI text models. The mix task does not accept a comma-separated model list as a single CLI spec; run explicit models one at a time or add a fixture-backed selector before the next broad replay gate.

OpenAI non-text modality assessment:

| Modality | Coverage module | Registry models | Current fixture state |
| --- | --- | --- | --- |
| Embeddings | `ReqLLM.ProviderTest.Embedding` / `test/coverage/openai/embedding_test.exs` | `text-embedding-3-small`, `text-embedding-3-large`, `text-embedding-ada-002` | all three models have fresh `embed_basic` and `embed_batch` fixtures and replay cleanly |
| Image generation | `ReqLLM.ProviderTest.ImageGeneration` / `test/coverage/openai/image_generation_test.exs` | `chatgpt-image-latest`, `gpt-image-1-mini`, `gpt-image-1.5`, `gpt-image-2`, `gpt-image-2-2026-04-21` | `gpt-image-1.5` has a fresh `image_basic` fixture and replays cleanly; the others remain expansion candidates |
| Speech / TTS | `ReqLLM.ProviderTest.Speech` / `test/coverage/openai/speech_test.exs` | `gpt-4o-mini-tts`, `gpt-4o-mini-tts-2025-12-15`, `tts-1`, `tts-1-1106`, `tts-1-hd`, `tts-1-hd-1106` | `tts-1` has a fresh `speech_basic` fixture and replays cleanly after binary response replay hardening; the others remain expansion candidates |
| Transcription | `ReqLLM.ProviderTest.Transcription` / `test/coverage/openai/transcription_test.exs` | `gpt-4o-mini-transcribe`, dated mini transcribe ids, `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`, `gpt-realtime-whisper`, `whisper-1` | `whisper-1` has a fresh `transcription_basic` fixture and replays cleanly after multipart request capture hardening; the others remain expansion candidates |

OpenAI non-text record/replay checks run during this pass:

```bash
set -a && source ./.env && set +a
MIX_ENV=test mix mc "openai:text-embedding-3-small" --type embedding --record --max-concurrency 1
MIX_ENV=test mix mc "openai:text-embedding-3-large" --type embedding --record --max-concurrency 1
MIX_ENV=test mix mc "openai:text-embedding-ada-002" --type embedding --record --max-concurrency 1
MIX_ENV=test mix mc "openai:text-embedding-3-small" --type embedding --max-concurrency 1
MIX_ENV=test mix mc "openai:text-embedding-3-large" --type embedding --max-concurrency 1
MIX_ENV=test mix mc "openai:text-embedding-ada-002" --type embedding --max-concurrency 1
MIX_ENV=test mix mc "openai:tts-1" --type speech --scenario speech_basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:tts-1" --type speech --scenario speech_basic --max-concurrency 1
MIX_ENV=test mix mc "openai:whisper-1" --type transcription --scenario transcription_basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:whisper-1" --type transcription --scenario transcription_basic --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-image-1.5" --type image --scenario image_basic --record --max-concurrency 1
MIX_ENV=test mix mc "openai:gpt-image-1.5" --type image --scenario image_basic --max-concurrency 1
```

Tooling fixes learned from this pass:

1. `ReqLLM.Test.VCR.replay_response_body/1` must preserve non-JSON binary bodies, not force every non-streaming fixture through `Jason.decode!/1`.
2. Replayed fixture headers must be normalized to Req's response header map shape before Req response steps run.
3. Multipart/non-JSON request bodies should be represented as compact metadata in fixture request snapshots rather than decoded as JSON or stored as raw audio payloads.
4. Legacy chat/text fixture files under embedding model directories were removed because operation filtering now keeps embedding models out of text comprehensive coverage.

Useful next commands:

```bash
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:tts-1-hd" --type speech --scenario speech_basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o-mini-tts" --type speech --scenario speech_basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-4o-transcribe" --type transcription --scenario transcription_basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-image-1-mini" --type image --scenario image_basic --record --max-concurrency 1
set -a && source ./.env && set +a && MIX_ENV=test mix mc "openai:gpt-image-2" --type image --scenario image_basic --record --max-concurrency 1
```

## Conservative Refresh Model List

These are the in-scope current-registry, passing, fixture-backed models from the provider sections of `MIX_ENV=test mix mc`. Azure entries are deliberately omitted for this pass. Anthropic and current OpenAI core text entries are already refreshed on this branch; the remaining providers should be handled one provider at a time.

### anthropic

- `anthropic:claude-haiku-4-5-20251001`
- `anthropic:claude-opus-4-1-20250805`
- `anthropic:claude-opus-4-20250514`
- `anthropic:claude-opus-4-5`
- `anthropic:claude-opus-4-5-20251101`
- `anthropic:claude-opus-4-6`
- `anthropic:claude-opus-4-7`
- `anthropic:claude-opus-4-8`
- `anthropic:claude-sonnet-4-20250514`
- `anthropic:claude-sonnet-4-5-20250929`
- `anthropic:claude-sonnet-4-6`

### cerebras

- `cerebras:gpt-oss-120b`
- `cerebras:qwen-3-235b-a22b-instruct-2507`
- `cerebras:qwen-3-coder-480b`

### google

- `google:gemini-2.0-flash`
- `google:gemini-2.0-flash-exp`
- `google:gemini-2.0-flash-lite`
- `google:gemini-2.5-flash`
- `google:gemini-2.5-pro`
- `google:gemini-flash-latest`

### groq

- `groq:llama-3.1-8b-instant`
- `groq:llama-3.3-70b-versatile`
- `groq:meta-llama/llama-4-maverick-17b-128e-instruct`
- `groq:moonshotai/kimi-k2-instruct-0905`
- `groq:openai/gpt-oss-120b`
- `groq:openai/gpt-oss-20b`
- `groq:qwen/qwen3-32b`

### minimax

- `minimax:MiniMax-M2`
- `minimax:MiniMax-M2.1`
- `minimax:MiniMax-M2.5`
- `minimax:MiniMax-M2.5-highspeed`
- `minimax:MiniMax-M2.7`
- `minimax:MiniMax-M2.7-highspeed`

### openai

- `openai:gpt-4.1`
- `openai:gpt-4.1-2025-04-14`
- `openai:gpt-4.1-mini`
- `openai:gpt-4.1-mini-2025-04-14`
- `openai:gpt-4o`
- `openai:gpt-4o-2024-08-06`
- `openai:gpt-4o-2024-11-20`
- `openai:gpt-4o-mini`
- `openai:gpt-5`
- `openai:gpt-5-2025-08-07`
- `openai:gpt-5-mini`
- `openai:gpt-5-mini-2025-08-07`
- `openai:gpt-5-nano`
- `openai:gpt-5-nano-2025-08-07`
- `openai:o3`
- `openai:o3-2025-04-16`
- `openai:gpt-image-1.5`
- `openai:text-embedding-3-large`
- `openai:text-embedding-3-small`
- `openai:text-embedding-ada-002`
- `openai:tts-1`
- `openai:whisper-1`

OpenAI pro follow-up candidates with only `basic` fixtures refreshed so far:

- `openai:gpt-5-pro`
- `openai:gpt-5-pro-2025-10-06`
- `openai:o3-pro`
- `openai:o3-pro-2025-06-10`

### openrouter

- `openrouter:anthropic/claude-3.5-haiku`
- `openrouter:anthropic/claude-3.7-sonnet`
- `openrouter:anthropic/claude-haiku-4.5`
- `openrouter:anthropic/claude-opus-4`
- `openrouter:anthropic/claude-opus-4.1`
- `openrouter:anthropic/claude-sonnet-4`
- `openrouter:anthropic/claude-sonnet-4.5`
- `openrouter:deepseek/deepseek-chat-v3-0324`
- `openrouter:deepseek/deepseek-r1-distill-llama-70b`
- `openrouter:google/gemini-2.0-flash-001`
- `openrouter:google/gemini-2.5-flash`
- `openrouter:google/gemini-2.5-flash-lite`
- `openrouter:google/gemini-2.5-flash-lite-preview-09-2025`
- `openrouter:google/gemini-2.5-pro`
- `openrouter:google/gemini-2.5-pro-preview-05-06`
- `openrouter:google/gemini-3-flash-preview`
- `openrouter:google/gemma-3n-e4b-it`
- `openrouter:meta-llama/llama-3.2-11b-vision-instruct`
- `openrouter:mistralai/codestral-2508`
- `openrouter:mistralai/mistral-medium-3`
- `openrouter:mistralai/mistral-medium-3.1`
- `openrouter:moonshotai/kimi-k2`
- `openrouter:moonshotai/kimi-k2-0905`
- `openrouter:nousresearch/hermes-4-70b`
- `openrouter:openai/gpt-4o-mini`
- `openrouter:openai/gpt-5`
- `openrouter:openai/gpt-5-codex`
- `openrouter:openai/gpt-5-mini`
- `openrouter:openai/gpt-5-nano`
- `openrouter:openai/gpt-5-pro`
- `openrouter:openai/gpt-oss-120b`
- `openrouter:openai/gpt-oss-20b`
- `openrouter:openai/o4-mini`
- `openrouter:qwen/qwen-2.5-coder-32b-instruct`
- `openrouter:qwen/qwen2.5-vl-72b-instruct`
- `openrouter:qwen/qwen3-235b-a22b-thinking-2507`
- `openrouter:qwen/qwen3-30b-a3b-instruct-2507`
- `openrouter:qwen/qwen3-30b-a3b-thinking-2507`
- `openrouter:qwen/qwen3-next-80b-a3b-thinking`
- `openrouter:x-ai/grok-3-mini`
- `openrouter:x-ai/grok-3-mini-beta`
- `openrouter:z-ai/glm-4.5`
- `openrouter:z-ai/glm-4.5-air`
- `openrouter:z-ai/glm-4.5v`
- `openrouter:z-ai/glm-4.6`

### xai

- `xai:grok-3`
- `xai:grok-3-mini`
- `xai:grok-3-mini-fast`
- `xai:grok-3-mini-fast-latest`
- `xai:grok-3-mini-latest`
- `xai:grok-4`
- `xai:grok-4-fast`
- `xai:grok-4-fast-non-reasoning`
- `xai:grok-4-fast-reasoning`
- `xai:grok-code-fast-1`

### zai

- `zai:glm-4.5`
- `zai:glm-4.5-air`
- `zai:glm-4.5-flash`
- `zai:glm-4.5v`
- `zai:glm-4.6`

### zai_coder

- `zai_coder:glm-4.5`
- `zai_coder:glm-4.5-air`
- `zai_coder:glm-4.5-flash`
- `zai_coder:glm-4.5v`
- `zai_coder:glm-4.6`

## Comprehensive Suite Cleanup Plan

The 10-model process check showed why broad whole-model recording was too noisy. The current branch now has scenario/capability selectors, scenario-level state, and staged recording, so the remaining work is to tighten the compatibility contract and docs before large provider batches.

Current suite status:

1. The comprehensive module doc says "up to 9" tests per model, but the current macro emits 11 scenario tags: `basic`, `streaming`, `token_limit`, `usage`, `context_append`, `tool_multi`, `tool_round_trip`, `tool_none`, `object_basic`, `object_streaming`, and `reasoning`.
2. `test/AGENTS.md` documents scenario filtering, but it is missing newer scenarios such as `context_append` and `tool_round_trip`.
3. `mix mc` now exposes `--scenario` and `--capability`, so fixture refreshes can run scenario-first without bypassing model compatibility reporting.
4. `priv/model_compat_scenarios.json` now records scenario status; `priv/supported_models.json` remains model-level state.
5. Capability predicates still need tightening before recording advanced scenarios. For example, object-generation tests should depend on explicit strict/streaming structured-output support, not broad tool availability.

Recommended compatibility contract:

| Layer | Scenarios | Meaning |
| --- | --- | --- |
| Core text | `basic`, `usage`, `token_limit` | Minimum text model compatibility |
| Conversation | `context_append` | Context advancement and assistant-message append behavior |
| Streaming | `streaming` | Text streaming plus usage/final response assembly |
| Tools | `tool_none`, `tool_multi`, `tool_round_trip` | Tool availability, tool choice, and tool-result continuation |
| Objects | `object_basic`, `object_streaming` | Structured output and streaming structured output |
| Reasoning | `reasoning` | Reasoning params, thinking content, and reasoning usage |
| Embeddings | `embed_basic`, `embed_batch` | Separate embedding compatibility path |
| Specialty | web search, web fetch, image, TTS, rerank | Provider-specific suites outside text model compatibility |

Implemented tooling sequence:

1. `mix mc --scenario` supports one or more scenario tags.
2. `mix mc --capability` supports `core`, `conversation`, `streaming`, `tools`, `objects`, `reasoning`, `embedding`, `image`, `speech`, `transcription`, `rerank`, and `ocr`.
3. Scenario state is tracked in `priv/model_compat_scenarios.json`.
4. Replay is read-only by default and only writes state with `--update-state`, `--record`, or `--record-all`.
5. Record mode stages fixtures and promotes only after the child ExUnit run passes.
6. Record mode defaults to low concurrency and accepts `--max-concurrency`.
7. Provider-operation selection now keeps specialty model families out of text refreshes.
8. Provider coverage macros exist for image generation, speech, transcription, rerank, and OCR.

Remaining tooling polish:

1. Add a scenario manifest that defines each scenario's tag, fixture files, capability requirement, and default record order.
2. Do not promote a model to whole-model `pass` unless all required scenarios for that model's declared capabilities pass in replay mode.
3. Tighten capability gating before recording advanced scenarios. Object streaming, forced tool choice, reasoning, and provider-specific parameter profiles should each have explicit checks instead of broad inference.
4. Update `test/AGENTS.md` and the comprehensive module docs so the documented scenarios match the generated tests.
5. Add a selector for "currently passing fixture-backed models" to avoid hand-running the conservative refresh set.
6. Add a fixture hygiene pass for older untouched OpenAI fixtures that still contain raw Cloudflare cookie values.
7. After recording any live scenario batch, immediately replay the same provider/model/scenario set before staging fixture files.

Fixture cleanup rule for this branch: keep passing replay-validated fixture updates in small commits, and discard failed partial writes unless the failing fixture is intentionally part of a documented provider behavior test.

## Review Decision Points

Before the next live batch, decide:

1. Whether to run full comprehensive suites for OpenAI `gpt-5-pro` and `o3-pro`, or keep them at basic fixture coverage for now.
2. Whether OpenAI Pro, OpenAI GPT-5.1+ basic-probed families, and OpenAI non-text coverage should be next, or whether to move to `google`, `groq`, `xai`, and `cerebras`.
3. Whether Minimax should be refreshed now that balance is updated, or deferred until after the higher-volume text providers.
4. Whether Fireworks, Zenmux, Venice, ElevenLabs, and Cohere should be separate provider-specific PRs instead of one expansion PR.
5. Whether to add the fixture-backed selector before more broad refresh work.
6. Whether to run OpenAI fixture cookie hygiene globally, since older unchanged OpenAI fixtures still contain raw Cloudflare cookie values.
