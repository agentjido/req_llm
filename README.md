# ReqLLM

[![Hex.pm](https://img.shields.io/hexpm/v/req_llm.svg)](https://hex.pm/packages/req_llm)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/req_llm)
[![License](https://img.shields.io/hexpm/l/req_llm.svg)](https://github.com/agentjido/req_llm/blob/main/LICENSE)
[![Discord](https://img.shields.io/discord/1234567890?color=7289da&label=discord&logo=discord&logoColor=white)](https://agentjido.xyz/discord)

> **Join the community!** Come chat about building AI tools with Elixir and coding Elixir with LLMs in [The Swarm: Elixir AI Collective](https://agentjido.xyz/discord) Discord server.

A [Req](https://github.com/wojtekmach/req)-based package to call LLM APIs that standardizes the API calls and responses for LLM providers.

## Why Req LLM?

LLM APIs are inconsistent. ReqLLM provides a unified, idiomatic Elixir interface with standardized requests and responses across providers.

**Two-layer architecture:**

- **High-level API** – Vercel AI SDK-inspired functions (`generate_text/3`, `stream_text/3`, `generate_object/4` and more) that work uniformly across providers. Standard features, minimal configuration.
- **Low-level API** – Direct Req plugin access for full HTTP control. Built around OpenAI Chat Completions baseline with provider-specific callbacks for non-compatible APIs (e.g., Anthropic).

**Supported Providers:** Anthropic, OpenAI, Google, Groq, OpenRouter, xAI, AWS Bedrock, Cerebras, Meta, Z.AI, and more. See provider guides in [documentation](https://hexdocs.pm/req_llm) for details.

\* _Streaming uses Finch directly due to known Req limitations with SSE responses._

## Quick Start

```elixir
# Keys are picked up from .env files or environment variables - see `ReqLLM.Keys`
model = "anthropic:claude-haiku-4-5"

ReqLLM.generate_text!(model, "Hello world")
#=> "Hello! How can I assist you today?"

schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!(model, "Generate a person", schema)
#=> %{name: "John Doe", age: 30}

{:ok, response} = ReqLLM.generate_text(
  model,
  ReqLLM.Context.new([
    ReqLLM.Context.system("You are a helpful coding assistant"),
    ReqLLM.Context.user("Explain recursion in Elixir")
  ]),
  temperature: 0.7,
  max_tokens: 200
)


{:ok, response} = ReqLLM.generate_text(
  model,
  "What's the weather in Paris?",
  tools: [
    ReqLLM.tool(
      name: "get_weather",
      description: "Get current weather for a location",
      parameter_schema: [
        location: [type: :string, required: true, doc: "City name"]
      ],
      callback: {Weather, :fetch_weather, [:extra, :args]}
    )
  ]
)

# Streaming text generation
{:ok, response} = ReqLLM.stream_text(model, "Write a short story")
ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&IO.write/1)
|> Stream.run()

# Access usage metadata after streaming
usage = ReqLLM.StreamResponse.usage(response)
```

## Features

- **Provider-agnostic model registry**
  - 45 providers / 665+ models auto-synced from [models.dev](https://models.dev) (`mix req_llm.model_sync`)
  - Cost, context length, modality, capability and deprecation metadata included

- **Canonical data model**
  - Typed `Context`, `Message`, `ContentPart`, `Tool`, `StreamChunk`, `Response`, `Usage`
  - Multi-modal content parts (text, image URL, tool call, binary)
  - All structs implement `Jason.Encoder` for simple persistence / inspection

- **Two client layers**
  - Low-level Req plugin with full HTTP control (`Provider.prepare_request/4`, `attach/3`)
  - High-level Vercel-AI style helpers (`generate_text/3`, `stream_text/3`, `generate_object/4`, bang variants)

- **Structured object generation**
  - `generate_object/4` renders JSON-compatible Elixir maps validated by a NimbleOptions-compiled schema
  - Zero-copy mapping to provider JSON-schema / function-calling endpoints
  - OpenAI native structured outputs with three modes (`:auto` (default), `:json_schema`, `:tool_strict`)

- **Embedding generation**
  - Single or batch embeddings via `Embedding.generate/3` (Not all providers support this)
  - Automatic dimension / encoding validation and usage accounting

- **Production-grade streaming**
  - `stream_text/3` returns a `StreamResponse` with both real-time tokens and async metadata
  - Finch-based streaming with HTTP/2 multiplexing and automatic connection pooling
  - Concurrent metadata collection (usage, finish_reason) without blocking token flow
  - Works uniformly across providers with internal SSE / chunked-response adaptation

- **Usage & cost tracking**
  - `response.usage` exposes input/output tokens and USD cost, calculated from model metadata or provider invoices

- **Schema-driven option validation**
  - All public APIs validate options with NimbleOptions; errors are raised as `ReqLLM.Error.Invalid.*` (Splode)

- **Automatic parameter translation & codecs**
  - Provider DSL translates canonical options (e.g. `max_tokens` -> `max_completion_tokens` for o1 & o3) to provider-specific names
  - Built-in OpenAI-style encoding/decoding with provider callback overrides for custom formats

- **Flexible model specification**
  - Accepts `"provider:model"`, `{:provider, "model", opts}` tuples, or `%ReqLLM.Model{}` structs
  - Helper functions for parsing, introspection and default-merging

- **Secure, layered key management** (`ReqLLM.Keys`)  
  - Per-request override → application config → env vars / .env files  

- **Extensive reliability tooling**
  - Fixture-backed test matrix (`LiveFixture`) supports cached, live, or provider-filtered runs
  - Dialyzer, Credo strict rules, and no-comment enforcement keep code quality high

## API Key Management

ReqLLM makes key management as easy and flexible as possible - this needs to _just work_.

**Please submit a PR if your key management use case is not covered**

Keys are pulled from multiple sources with clear precedence: per-request override → in-memory storage → application config → environment variables → .env files.

```elixir
# Store keys in memory (recommended)
ReqLLM.put_key(:openai_api_key, "sk-...")
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

# Retrieve keys with source info
{:ok, key, source} = ReqLLM.get_key(:openai)
```

All functions accept an `api_key` parameter to override the stored key:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", api_key: "sk-ant-...")
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Story", api_key: "sk-ant-...")
```

## Usage Cost Tracking

Every response includes detailed usage and cost information calculated from model metadata:

```elixir
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

response.usage
#=> %{
#     input_tokens: 8,
#     output_tokens: 12,
#     total_tokens: 20,
#     input_cost: 0.00024,
#     output_cost: 0.00036,
#     total_cost: 0.0006
#   }
```

A telemetry event `[:req_llm, :token_usage]` is published on every request with token counts and calculated costs.

## Streaming Configuration

ReqLLM uses Finch for streaming connections with automatic connection pooling. By default, we use HTTP/1-only pools to work around a known Finch bug with large request bodies:

```elixir
# Default configuration (automatic)
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 8]
    }
  ]
```

### HTTP/2 Configuration (Advanced)

**Important:** Due to [Finch issue #265](https://github.com/sneako/finch/issues/265), HTTP/2 pools may fail when sending request bodies larger than 64KB (large prompts, extensive context windows). This is a bug in Finch's HTTP/2 flow control implementation, not a limitation of HTTP/2 itself.

If you want to use HTTP/2 pools (e.g., for performance testing or if you know your prompts are small), you can configure it:

```elixir
# HTTP/2 configuration (use with caution)
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http2, :http1], size: 1, count: 8]
    }
  ]
```

**ReqLLM will error with a helpful message if you try to send a large request body with HTTP/2 pools.** The error will reference this section for configuration guidance.

For high-scale deployments with small prompts, you can increase the connection count:

```elixir
# High-scale configuration
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 32]  # More connections
    }
  ]
```

Advanced users can specify custom Finch instances per request:

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages, finch_name: MyApp.CustomFinch)
```

### StreamResponse Usage Patterns

The new `StreamResponse` provides flexible access patterns:

```elixir
# Real-time streaming for UI
{:ok, response} = ReqLLM.stream_text(model, "Tell me a story")

ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&broadcast_to_liveview/1)
|> Stream.run()

# Concurrent metadata collection (non-blocking)
Task.start(fn ->
  usage = ReqLLM.StreamResponse.usage(response)
  log_usage(usage)
end)

# Simple text collection
text = ReqLLM.StreamResponse.text(response)

# Backward compatibility with legacy Response
{:ok, legacy_response} = ReqLLM.StreamResponse.to_response(response)
```

## Adding a Provider

ReqLLM uses OpenAI Chat Completions as the baseline API standard. Providers that support this format (like Groq, OpenRouter, xAI) require minimal overrides using the `ReqLLM.Provider.DSL`. Model metadata is automatically synced from [models.dev](https://models.dev).

Providers implement the `ReqLLM.Provider` behavior with functions like `encode_body/1`, `decode_response/1`, and optional parameter translation via `translate_options/3`.

See the [Adding a Provider Guide](guides/adding_a_provider.md) for detailed implementation instructions.

## Lower-Level Req Plugin API

For advanced use cases, you can use ReqLLM providers directly as Req plugins. This is the canonical implementation used by `ReqLLM.generate_text/3`:

```elixir
# The canonical pattern from ReqLLM.Generation.generate_text/3
with {:ok, model} <- ReqLLM.Model.from("anthropic:claude-haiku-4-5"), # Parse model spec
     {:ok, provider_module} <- ReqLLM.provider(model.provider),        # Get provider module
     {:ok, request} <- provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7), # Build Req request
     {:ok, %Req.Response{body: response}} <- Req.request(request) do   # Execute HTTP request
  {:ok, response}
end

# Customize the Req pipeline with additional headers or middleware
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")
{:ok, provider_module} = ReqLLM.provider(model.provider)
{:ok, request} = provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7)

# Add custom headers or middleware before sending
custom_request =
  request
  |> Req.Request.put_header("x-request-id", "my-custom-id")
  |> Req.Request.put_header("x-source", "my-app")

{:ok, response} = Req.request(custom_request)
```

This approach gives you full control over the Req pipeline, allowing you to add custom middleware, modify requests, or integrate with existing Req-based applications.

## Documentation

- [Getting Started](guides/getting-started.md) – first call and basic concepts
- [Core Concepts](guides/core-concepts.md) – architecture & data model
- [Data Structures](guides/data-structures.md) – detailed type information
- [Mix Tasks](guides/mix-tasks.md) – model sync, compatibility testing, code generation
- [Fixture Testing](guides/fixture-testing.md) – model validation and supported models
- [Adding a Provider](guides/adding_a_provider.md) – extend with new providers
- Provider Guides: [Anthropic](guides/anthropic.md), [OpenAI](guides/openai.md), [Google](guides/google.md), [xAI](guides/xai.md), [Groq](guides/groq.md), [OpenRouter](guides/openrouter.md), [Amazon Bedrock](guides/amazon_bedrock.md), [Cerebras](guides/cerebras.md), [Meta](guides/meta.md), [Z.AI](guides/zai.md), [Z.AI Coder](guides/zai_coder.md)



## Roadmap & Status

ReqLLM has now reached v1.0.0. The core API is stable and ready for production use. We're continuing to refine the library and would love community feedback as we plan the next set of improvements. If you run into anything or have suggestions, please open an issue or PR.

### Test Coverage & Quality Commitment

**130+ models currently pass our comprehensive fixture-based test suite** across 10 providers. The LLM API landscape is highly dynamic. We guarantee that all supported models pass our fixture tests for basic functionality (text generation, streaming, tool calling, structured output, and embeddings where applicable).

These fixture tests are regularly refreshed against live APIs to ensure accuracy and catch provider-side changes. While we can't guarantee every edge case in production, our fixture-based approach provides a reliable baseline that you can verify with `mix mc "*:*"`.

**We welcome bug reports and feedback!** If you encounter issues with any supported model, please open a GitHub issue with details. The more feedback we receive, the stronger the code will be!

## Development

```bash
# Install dependencies
mix deps.get

# Run tests with cached fixtures
mix test

# Run quality checks
mix quality  # format, compile, dialyzer, credo

# Generate documentation
mix docs
```

### Testing with Fixtures

Tests use cached JSON fixtures by default. To regenerate fixtures against live APIs (optional):

```bash
# Regenerate all fixtures
LIVE=true mix test

# Regenerate specific provider fixtures using test tags
LIVE=true mix test --only "provider:anthropic"
```

## Contributing

We welcome contributions! ReqLLM uses a fixture-based testing approach to ensure reliability across all providers.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:

- Core library contributions
- Adding new providers
- Extending provider features
- Testing requirements and fixture generation
- Code quality standards

Quick start:

1. Fork the repository
2. Create a feature branch
3. Add tests with fixtures for your changes
4. Run `mix test` and `mix quality` to ensure standards
5. Verify `mix mc "*:*"` passes for affected providers
6. Submit a pull request

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
