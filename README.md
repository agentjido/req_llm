# ReqLLM

[![Hex.pm](https://img.shields.io/hexpm/v/req_llm.svg)](https://hex.pm/packages/req_llm)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/req_llm)
[![License](https://img.shields.io/hexpm/l/req_llm.svg)](https://github.com/agentjido/req_llm/blob/main/LICENSE)

A [Req](https://github.com/wojtekmach/req)-based library for LLM interactions, providing a unified interface to AI providers through a plugin-based architecture.

## Why ReqLLM?

ReqLLM brings the composability and middleware advantages of the Req ecosystem to LLM interactions. With its plugin architecture, provider/model auto-sync, typed data structures, and ergonomic helpers, it provides a robust foundation for building AI-powered applications in Elixir while leveraging Req's powerful middleware, tracing, and instrumentation capabilities.

## Installation

Add `req_llm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:req_llm, "~> 1.0-rc"}
  ]
end
```

**Requirements:** Elixir ~> 1.15, OTP 24+

## Features

- **45 providers / 665+ models** auto-synced from [models.dev](https://models.dev) (`mix req_llm.models.sync`)
  - Cost, context length, modality and capability metadata included
- **Typed data structures** for every call
  - Context, Message, ContentPart, StreamChunk, Tool
  - All structs are `Jason.Encoder`s and can be inspected / persisted
  
- **Two ergonomic client layers**
  - Low-level `Req` plugin interface with full HTTP + model metadata
  - Vercel AI-style helpers (`generate_text/3`, `stream_text/3`, bang `!` variants)
- **Streaming built in** (`ReqLLM.stream_text/3`) — each chunk is a `StreamChunk`
- **Usage & cost extraction** on every response (`response.usage`)
- **Plugin-based provider system**
  - Anthropic, OpenAI, Groq, Google, xAI and OpenRouter included
  - Easily extendable with new providers (see [Adding a Provider Guide](guides/adding_a_provider.md))
- **Context Codec protocol** converts ReqLLM structs to provider wire formats
- **Extensive test matrix** (local fixtures + optional live calls)

## Quick Start

```elixir
# Configure API keys using JidoKeys (secure, in-memory storage)
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

# Keys in .env are automatically picked up via the JidoKeys package via Dotenvy

model = "anthropic:claude-3-sonnet"

# Simple text generation
ReqLLM.generate_text!(model, "Hello world")
#=> "Hello! How can I assist you today?"

# Structured data generation
schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!(model, "Generate a person", schema)
#=> %{name: "John Doe", age: 30}

# With system prompts and parameters
{:ok, response} = ReqLLM.generate_text(
  model,
  [
    system("You are a helpful coding assistant"),
    user("Explain recursion in Elixir")
  ],
  temperature: 0.7,
  max_tokens: 200
)

# Tool calling
weather_tool = ReqLLM.tool(
  name: "get_weather",
  description: "Get current weather for a location",
  parameter_schema: [
    location: [type: :string, required: true, doc: "City name"]
  ],
  callback: fn args -> {:ok, "Sunny, 72°F"} end
)

{:ok, response} = ReqLLM.generate_text(
  model,
  "What's the weather in Paris?",
  tools: [weather_tool]
)

# Streaming text generation
ReqLLM.stream_text!(model, "Write a short story")
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Embeddings
{:ok, embeddings} = ReqLLM.embed_many("openai:text-embedding-3-small", ["Hello", "World"])
```

## Provider Support

| Provider   | Chat | Streaming | Tools | Embeddings |
|------------|------|-----------|-------|------------|
| Anthropic  | ✓    | ✓         | ✓     | ✗          |
| OpenAI     | ✓    | ✓         | ✓     | ✓          |
| Google     | ✓    | ✓         | ✓     | ✗          |
| Groq       | ✓    | ✓         | ✓     | ✗          |
| xAI        | ✓    | ✓         | ✓     | ✗          |
| OpenRouter | ✓    | ✓         | ✓     | ✗          |

## API Key Management with JidoKeys

ReqLLM uses [JidoKeys](https://hex.pm/packages/jido_keys) for secure in-memory key storage. Keys are never written to disk by default:

```elixir
# Store keys in memory
ReqLLM.put_key(:openai_api_key, System.get_env("OPENAI_API_KEY"))
ReqLLM.put_key(:anthropic_api_key, System.get_env("ANTHROPIC_API_KEY"))

# Or load from environment variables automatically
ReqLLM.put_key(:openai_api_key, {:env, "OPENAI_API_KEY"})

# Keys are automatically resolved when making requests
ReqLLM.generate_text!("openai:gpt-4", "Hello")
```

## Usage Cost Tracking

Every response includes detailed usage and cost information:

```elixir
{:ok, response} = ReqLLM.generate_text("openai:gpt-4", "Hello")

response.usage
#=> %ReqLLM.Usage{
#     input_tokens: 8,
#     output_tokens: 12,
#     total_tokens: 20,
#     input_cost: 0.00024,
#     output_cost: 0.00036,
#     total_cost: 0.0006
#   }
```

## Adding a Provider

See the [Adding a Provider Guide](guides/adding_a_provider.md) for detailed instructions on implementing new providers using the `ReqLLM.Plugin` behaviour.

## Lower-Level Req Plugin API

For advanced use cases, you can use ReqLLM providers directly as Req plugins:

```elixir
alias ReqLLM.Providers.Anthropic

# Configure your API key
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

# Build context and model
context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are a helpful assistant"),  
  ReqLLM.Context.user("Hello!")
])
model = ReqLLM.Model.from!("anthropic:claude-3-sonnet")

# Option 1: Use provider's prepare_request (recommended)
{:ok, request} = Anthropic.prepare_request(:chat, model, context, temperature: 0.7)
{:ok, response} = Req.request(request)

# Option 2: Build Req request manually with attach
request = 
  Req.new(url: "/messages", method: :post)
  |> Anthropic.attach(model, context: context, temperature: 0.7)

{:ok, response} = Req.request(request)

# Access response data
response.body["content"]
#=> [%{"type" => "text", "text" => "Hello! How can I help you today?"}]
```

This approach gives you full control over the Req pipeline, allowing you to add custom middleware, modify requests, or integrate with existing Req-based applications.

## Documentation

- [Getting Started](guides/getting-started.md) – first call and basic concepts
- [Core Concepts](guides/core-concepts.md) – architecture & data model
- [API Reference](guides/api-reference.md) – functions & types
- [Data Structures](guides/data-structures.md) – detailed type information
- [Capability Testing](guides/capability-testing.md) – testing strategies
- [Adding a Provider](guides/adding_a_provider.md) – extend with new providers

## Roadmap & Status

ReqLLM 1.0-rc.1 is a **release candidate**. The core API is stable, but minor breaking changes may occur before the final 1.0.0 release based on community feedback.

**Planned for 1.x:**
- Additional open-source providers (Ollama, LocalAI)
- Enhanced streaming capabilities
- Performance optimizations
- Extended model metadata

## Development

```bash
# Install dependencies
mix deps.get

# Run tests with cached fixtures
mix test

# Run tests against live APIs (regenerates fixtures)
LIVE=true mix test

# Run quality checks
mix q  # format, compile, dialyzer, credo

# Generate documentation
mix docs
```

### Testing with Fixtures

ReqLLM uses a sophisticated fixture system powered by `LiveFixture`:

- **Default mode**: Tests run against cached JSON fixtures
- **Live mode** (`LIVE=true`): Tests run against real APIs and regenerate fixtures
- **Provider filtering** (`FIXTURE_FILTER=anthropic`): Regenerate fixtures for specific providers only

## Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for your changes
4. Run `mix q` to ensure quality standards
5. Submit a pull request

### Running Tests

- `mix test` - Run all tests with fixtures
- `LIVE=true mix test` - Run against live APIs (requires API keys)
- `FIXTURE_FILTER=openai mix test` - Limit to specific provider

## License

Copyright 2025 Mike Hostetler

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
