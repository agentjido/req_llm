# GitHub Copilot Instructions for ReqLLM

## Project Overview

**ReqLLM** is a composable Elixir library for AI interactions built on Req, providing a unified interface to AI providers through a plugin-based architecture.

## Tech Stack

- **Language**: Elixir
- **HTTP Client**: Req
- **Testing**: ExUnit with fixture-based live/cached testing
- **Type Checking**: Dialyzer
- **Linting**: Credo

## Coding Guidelines

### Testing
- Use `mix test` for cached fixtures, `LIVE=true mix test` for live API calls
- Tests use `ReqLLM.Test.LiveFixture.use_fixture/3` for fixture management
- Run `mix quality` before committing

### Code Style
- No inline comments in function bodies
- Use pattern matching over conditionals
- Return `{:ok, result}` / `{:error, reason}` tuples
- Run `mix format` before committing

## Issue Tracking with bd

**CRITICAL**: This project uses **bd** for ALL task tracking. Do NOT create markdown TODO lists.

### Essential Commands

```bash
bd ready --json                    # Unblocked issues
bd create "Title" -t bug|feature|task -p 0-4 --json
bd update <id> --status in_progress --json
bd close <id> --reason "Done" --json
```

### Workflow

1. **Check ready work**: `bd ready --json`
2. **Claim task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Complete**: `bd close <id> --reason "Done" --json`
5. **Commit together**: Always commit `.beads/issues.jsonl` with code changes

## Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Run `mix quality` before committing
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT add comments inside function bodies

---

**For detailed workflows, see [AGENTS.md](../AGENTS.md)**
