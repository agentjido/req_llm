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

## Current Fixture State

The fixture tree has 2200 JSON fixture files under `test/support/fixtures`.

`MIX_ENV=test mix mc` reports:

| Provider | Pass | Fail | Excluded | Untested |
| --- | ---: | ---: | ---: | ---: |
| alibaba | 0 | 0 | 0 | 50 |
| alibaba_cn | 0 | 0 | 0 | 82 |
| amazon_bedrock | 0 | 4 | 0 | 88 |
| anthropic | 8 | 0 | 0 | 8 |
| azure | 26 | 0 | 0 | 77 |
| cerebras | 3 | 0 | 0 | 2 |
| cohere | 0 | 0 | 0 | 17 |
| elevenlabs | 0 | 0 | 0 | 4 |
| fireworks_ai | 0 | 0 | 0 | 12 |
| google | 6 | 0 | 1 | 43 |
| google_vertex | 0 | 0 | 0 | 40 |
| groq | 7 | 0 | 0 | 11 |
| minimax | 6 | 0 | 0 | 0 |
| openai | 22 | 2 | 0 | 107 |
| openrouter | 45 | 0 | 0 | 319 |
| venice | 0 | 0 | 0 | 67 |
| xai | 10 | 0 | 0 | 16 |
| zai | 5 | 0 | 0 | 8 |
| zai_coder | 5 | 0 | 0 | 0 |
| zai_coding_plan | 0 | 0 | 0 | 5 |
| zenmux | 0 | 0 | 0 | 149 |

The provider sections currently sum to 143 passing, fixture-backed, current-registry models. The active refresh scope excludes Azure, leaving 117 in-scope candidate passing models. Amazon Bedrock has no passing models in the current provider sections and stays out of triage for this pass. Minimax remains in the conservative candidate list; the earlier `429` was resolved by a balance update, but it was not retested during the tooling smoke slice. The task's overall line reports `169/1268` because the overall calculation also counts legacy `priv/supported_models.json` pass entries that are no longer in the current provider sections. Treat the in-scope model list below as the candidate refresh set.

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
| openai | 2026-05-01 |
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
| Minimax | `MINIMAX_API_KEY` | auth verified OK on models endpoint; balance has been updated; no further retest in this tooling slice |
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
```

Important behavior:

- `mix mc` with no spec prints current coverage and does not run tests.
- `mix mc --available` lists registry models and does not run tests.
- `mix mc --sample` runs tests for configured sample models.
- `mix mc "provider:*" --record` records every current registry model for that implemented provider, not just models with existing fixtures.
- `--type text` is the default.
- Use `--type embedding` for embedding fixture refresh.
- `--record` and `--record-all` both make live API calls for selected specs in the current task implementation.
- Replay checks are read-only by default.
- Use `--scenario` for one or more comma-separated scenario tags.
- Use `--capability core|conversation|streaming|tools|objects|reasoning|embedding` for scenario groups.
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

Conservative candidate target: re-record the 117 in-scope passing, fixture-backed, current-registry models listed below. This excludes Azure and Amazon Bedrock by scope. Minimax stays in the candidate list after the balance update, but should be refreshed in its own small provider pass. Amazon Bedrock has no passing models in the current provider-section count and stays out of triage for this pass.

For one model:

```bash
MIX_ENV=test mix mc "openai:gpt-4o-mini" --record
```

For broad provider recording, only use this after deciding that new untested registry models should be attempted too:

```bash
MIX_ENV=test mix mc "openai:*" --record
```

Recommended provider order:

1. `anthropic`, `openai`, `google`: highest-value smoke path and already have keys set.
2. `groq`, `openrouter`, `xai`, `cerebras`: keys are present, but expect provider-specific model drift.
3. `zai`, `zai_coder`: key is verified, but provider-specific fixture smoke still needs to run.
4. `minimax`: key is verified and balance has been updated; run it as a small provider pass rather than mixing it into the first broad core batch.
5. `fireworks_ai`, `zenmux`, `venice`: keys are verified; treat as expansion providers because they have no passing fixture-backed models in the current conservative list.
6. `elevenlabs`: key and TTS are verified, but it is speech/TTS coverage, not normal text `mix mc` coverage.
7. `deepseek`: key is verified, but this checkout currently has no LLMDB models for the `deepseek` provider.
8. `cohere`: key is verified, but this provider is rerank-only in ReqLLM.
9. `mistral`: key is verified; treat as an expansion provider because it has no passing fixture-backed models in the current conservative list.

### Phase 2: Triage Current Failing Fixture-Backed Models

Current failing fixture-backed models:

| Provider | Models |
| --- | --- |
| amazon_bedrock | `anthropic.claude-haiku-4-5-20251001-v1:0`, `anthropic.claude-opus-4-1-20250805-v1:0`, `anthropic.claude-sonnet-4-5-20250929-v1:0`, `meta.llama3-3-70b-instruct-v1:0` |
| openai | `gpt-5-pro`, `o3-pro` |

Skip the Amazon Bedrock failures for this pass. For OpenAI pro models, check whether current account access and model endpoint expectations still match ReqLLM's implementation before treating them as regressions.

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

## Conservative Refresh Model List

These are the in-scope current-registry, passing, fixture-backed models from the provider sections of `MIX_ENV=test mix mc`. Azure entries are deliberately omitted for this pass. Minimax remains listed as a candidate provider but should be skipped until the provider-side `429` clears.

### anthropic

- `anthropic:claude-3-5-haiku-20241022`
- `anthropic:claude-3-haiku-20240307`
- `anthropic:claude-haiku-4-5-20251001`
- `anthropic:claude-opus-4-1-20250805`
- `anthropic:claude-opus-4-20250514`
- `anthropic:claude-opus-4-8`
- `anthropic:claude-sonnet-4-20250514`
- `anthropic:claude-sonnet-4-5-20250929`

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

- `openai:gpt-4`
- `openai:gpt-4-turbo`
- `openai:gpt-4.1`
- `openai:gpt-4.1-mini`
- `openai:gpt-4.1-nano`
- `openai:gpt-4o`
- `openai:gpt-4o-2024-05-13`
- `openai:gpt-4o-2024-08-06`
- `openai:gpt-4o-2024-11-20`
- `openai:gpt-4o-mini`
- `openai:gpt-5`
- `openai:gpt-5-chat-latest`
- `openai:gpt-5-codex`
- `openai:gpt-5-mini`
- `openai:gpt-5-nano`
- `openai:o1`
- `openai:o3`
- `openai:o3-mini`
- `openai:o4-mini`
- `openai:text-embedding-3-large`
- `openai:text-embedding-3-small`
- `openai:text-embedding-ada-002`

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

The 10-model process check shows that the suite needs a more formal compatibility contract before broad fixture refresh. The current comprehensive macro already uses scenario tags, but `mix mc` only drives whole-model runs and stores only model-level pass/fail state. That makes one failing advanced scenario invalidate a model after earlier scenarios have already rewritten fixtures.

Current suite drift to clean up:

1. The comprehensive module doc says "up to 9" tests per model, but the current macro emits 11 scenario tags: `basic`, `streaming`, `token_limit`, `usage`, `context_append`, `tool_multi`, `tool_round_trip`, `tool_none`, `object_basic`, `object_streaming`, and `reasoning`.
2. `test/AGENTS.md` documents scenario filtering, but it is missing newer scenarios such as `context_append` and `tool_round_trip`.
3. `mix mc` does not expose a `--scenario` or `--capability` selector. Direct `mix test --only "scenario:basic"` works, but it bypasses model compatibility reporting and state updates.
4. `priv/supported_models.json` is model-level only. It cannot tell whether a model passes core text but fails streaming, object, tools, or reasoning.
5. Capability predicates are too broad for fixture recording. For example, object-generation tests run for any model with tool calling, even when the provider/model path may not support the specific strict or streaming object behavior the test expects.

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

Recommended implementation sequence:

1. Add a scenario manifest that defines each scenario's tag, fixture files, capability requirement, and default record order.
2. Add `mix mc --scenario basic,usage` and `mix mc --capability core|streaming|tools|objects|reasoning` so refreshes can be scenario-first while still using model compatibility reporting.
3. Add scenario-level state, either by expanding `priv/supported_models.json` with a `scenarios` map or by adding a separate generated artifact such as `priv/model_compat_scenarios.json`.
4. Do not promote a model to whole-model `pass` unless all required scenarios for that model's declared capabilities pass in replay mode.
5. Do not downgrade whole-model state after a partial scenario run. Record scenario status separately and compute whole-model status from the latest relevant scenario results.
6. Tighten capability gating before recording advanced scenarios. Object streaming, forced tool choice, reasoning, and provider-specific parameter profiles should each have explicit checks instead of broad "tools enabled" inference.
7. Update `test/AGENTS.md` and the comprehensive module docs so the documented scenarios match the generated tests.
8. After recording any live scenario batch, immediately replay the same provider/model/scenario set before staging fixture files.

Fixture cleanup rule for this branch: keep passing replay-validated fixture updates in small commits, and discard failed partial writes unless the failing fixture is intentionally part of a documented provider behavior test.

## Review Decision Points

Before recording broadly, decide:

1. Whether the first pass should refresh only the 117 in-scope current-registry candidate passing models, or intentionally expand into untested registry models.
2. Whether to add Fireworks, Mistral, Zenmux, and Venice expansion smoke tests after the conservative pass.
3. Whether ElevenLabs speech/TTS and Cohere rerank fixture coverage should be refreshed separately from text model compatibility.
4. Whether to triage OpenAI `gpt-5-pro` and `o3-pro` now or leave them failing until account access is confirmed.
5. Whether to leave Minimax paused until the provider-side `429` clears.
6. Whether to adjust the mix task so it can select "currently passing fixture-backed models" directly, avoiding hand-running many individual specs.
7. Whether the next PR should implement scenario-first `mix mc` support before any more broad fixture recording.
