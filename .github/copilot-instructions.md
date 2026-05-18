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

## Important Rules

- ✅ Run `mix quality` before committing
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT add comments inside function bodies

---

**For detailed workflows, see [AGENTS.md](../AGENTS.md)**
