# ReqLLM Examples

This directory is a nested Mix project for runnable ReqLLM examples.

## Quick Start

From the repo root:

```bash
cp examples/.env.example examples/.env
cd examples
mix deps.get
mix run demo.exs
```

Or work directly inside `examples/`:

```bash
cp .env.example .env
mix deps.get
mix run demo.exs
```

You need a working API key in `examples/.env`.
Most scripts default to OpenAI models. `demo.exs` uses Anthropic by default.

## What Is Here

- `demo.exs` runs the interactive agent demo.
- `lib/req_llm/examples/agent.ex` defines `ReqLLM.Examples.Agent`.
- `lib/req_llm/examples/helpers.ex` contains shared helpers for the scripts.
- `scripts/` contains standalone runnable examples for the main APIs.
- `playground.exs` starts the local playground UI.

## Common Commands

```bash
mix run demo.exs
mix run scripts/text_generate.exs "Explain functional programming"
mix run scripts/text_stream.exs "Write a haiku about code"
./scripts/run_all.sh
mix run playground.exs
```

See [scripts/README.md](scripts/README.md) for the individual script reference.
