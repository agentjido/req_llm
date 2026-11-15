---
title: Documentation inbox and intake log
status: current
last-reviewed: 2026-11-15
---

# Documentation inbox

The inbox is clear. It contains no unprocessed item.

## Intake log

| Source | Destination | Intake date | Status | Notes |
| --- | --- | --- | --- | --- |
| `COMPATIBILITY.md` | Retained at source; linked from `docs/README.md` | 2026-11-15 | fixed-path | The package and HexDocs use this path. |
| `guides/v2-migration-audit.md` | Retained at source; consolidated into the V2 documents | 2026-11-15 | placed | It remains the published migration guide. |
| `guides/provider-extension-decision.md` | Retained at source; consolidated into the V2 documents | 2026-11-15 | placed | It remains the published V1 decision. |
| GitHub issue `agentjido/req_llm#830` | `decisions/2026-11-15-v2-direction.md`, `plans/v2-scope.md`, `plans/v2-roadmap.md`, and `reference/v2-source-map.md` | 2026-11-15 | placed | The issue was closed on 2026-10-12. Its breaking scope is historical and is not part of the current stable-API architecture plan. |
| GitHub repository `mikehostetler/reqllm_next` | `reference/v2-source-map.md` and the V2 direction | 2026-11-15 | placed | This is an experimental source, not current ReqLLM authority. |

## Fixed-path exceptions

The root entry points, policy files, published `guides/`, agent instructions,
security policy, contribution guide, change log, and usage rules remain at
their current paths. Moving them would affect package, HexDocs, or repository
consumers.
