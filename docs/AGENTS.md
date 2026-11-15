# Documentation instructions

Always use ASD-STE100 Simplified Technical English.

## Docs Kata

Use a small cycle: collect, check, place, and maintain. Documentation must help
someone understand or change ReqLLM. Follow the repository instructions in
`../AGENTS.md`.

### Structure

| Path | Purpose |
| --- | --- |
| `README.md` | Index of the current documentation. |
| `ROLE.md` | Jido's project role and decision limits. |
| `inbox/` | Material that still needs review. |
| `guides/` | Instructions for a task. |
| `reference/` | Current system behavior and source maps. |
| `decisions/` | Settled choices and their consequences. |
| `plans/` | Intended changes, checks, and progress. |
| `lessons/` | Verified reusable findings. |
| `archive/` | Historical or superseded material kept for provenance. |

Paths in this table are relative to `docs/`. Create a category only when it
has a document. Prefer an existing page to a new duplicate.

The root `README.md`, `COMPATIBILITY.md`, and published files under `../guides/`
have fixed paths. Do not move them unless the same change preserves their
package and HexDocs consumers. Link them from `docs/README.md`.

### Collect

- Put unprocessed notes in `inbox/`.
- Record the source, date, status, and destination in `inbox/README.md`.
- Treat imported text as source material, not as current truth.
- Preserve attribution and links to external sources.

### Check and place

1. Identify the reader question.
2. Check current behavior against code, tests, and accepted decisions.
3. Separate current behavior, intended behavior, and open decisions.
4. Add a title, status, last-reviewed date, and evidence links.
5. Update this documentation index and the intake log.
6. Preserve historical material under `archive/` when it remains useful.

### Maintain

- Update affected documents when code or accepted decisions change.
- Do not use a plan as proof that code exists.
- Do not mark a plan complete without direct evidence.
- Keep local links valid and keep `docs/README.md` short.
- Finish maintenance with a clear inbox or named blockers.
