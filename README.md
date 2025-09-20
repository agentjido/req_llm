# ReqLLM

[![Hex.pm](https://img.shields.io/hexpm/v/req_llm.svg)](https://hex.pm/packages/req_llm)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/req_llm)
[![License](https://img.shields.io/hexpm/l/req_llm.svg)](https://github.com/agentjido/req_llm/blob/main/LICENSE)

A [Req](https://github.com/wojtekmach/req)-based package to call LLM APIs. The purpose is to standardize the API calls and API responses for all supported LLM providers.

## Why Req LLM?

LLM API's are often inconsistent. ReqLLM aims to provide a consistent, data-driven, idiomatic Elixir interface to make requests to these API's and standardize the responses, making it easier to work with LLMs in Elixir.  

This package provides **two-layers** of client interfaces. The top layer is a high-level, provider-agnostic interface that mimic's the Vercel AI SDK and lives in `ReqLLM.ex` using methods like `generate_text/3`. This package seeks to standardize this high-level API across all supported providers, making it easy for Elixir developers to with standard features supported by LLMs. However, any high level abstraction requires trade-offs in terms of flexibility and customization.

The low-level client interface directly utilizes `Req` plugins to make HTTP requests to the LLM API's.  This layer is more flexible and customizable, but requires more knowledge of the underlying API's.  This package is built around the OpenAI API Baseline standard, making it easier to implement providers that follow this standard. Providers such as _Anthropic_ who do not follow the OpenAI standard are heavily customized through callbacks and protocols.

## Quick Start

```elixir
# Keys are picked up from .env files or environment variables - see `ReqLLM.Keys`
model = "anthropic:claude-3-sonnet"

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

ReqLLM.stream_text!(model, "Write a short story")
|> Stream.each(&IO.write(&1.text))
|> Stream.run()
```

## Features

- **Provider-agnostic model registry**  
  - 45 providers / 665+ models auto-synced from [models.dev](https://models.dev) (`mix req_llm.models.sync`)  
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

- **Embedding generation**  
  - Single or batch embeddings via `Embedding.generate/3` (Not all providers support this)
  - Automatic dimension / encoding validation and usage accounting

- **First-class streaming**  
  - `stream_text/3` returns a lazy `Stream` of `StreamChunk` structs with delta text, role, index  
  - Works uniformly across providers with internal SSE / chunked-response adaptation  

- **Usage & cost tracking**  
  - `response.usage` exposes input/output tokens and USD cost, calculated from model metadata or provider invoices  

- **Schema-driven option validation**  
  - All public APIs validate options with NimbleOptions; errors are raised as `ReqLLM.Error.Invalid.*` (Splode)  

- **Automatic parameter translation & codecs**  
  - Provider DSL translates canonical options (e.g. `max_tokens` -> `max_completion_tokens` for o1 & o3) to provider-specific names  
  - `Context.Codec` and `Response.Codec` protocols map ReqLLM structs to wire formats and back  

- **Flexible model specification**  
  - Accepts `"provider:model"`, `{:provider, "model", opts}` tuples, or `%ReqLLM.Model{}` structs  
  - Helper functions for parsing, introspection and default-merging  

- **Secure, layered key management** (`ReqLLM.Keys`)  
  - Per-request override → in-memory keyring (JidoKeys) → application config → env vars /.env files  

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
ReqLLM.generate_text("openai:gpt-4", "Hello", api_key: "sk-...")
ReqLLM.stream_text("anthropic:claude-3-sonnet", "Story", api_key: "sk-ant-...")
```

## Usage Cost Tracking

Every response includes detailed usage and cost information calculated from model metadata:

```elixir
{:ok, response} = ReqLLM.generate_text("openai:gpt-4", "Hello")

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

## Adding a Provider

ReqLLM uses OpenAI Chat Completions as the baseline API standard. Providers that support this format (like Groq, OpenRouter, xAI) require minimal overrides using the `ReqLLM.Provider.DSL`. Model metadata is automatically synced from [models.dev](https://models.dev).

Providers implement the `ReqLLM.Provider` behavior with functions like `encode_body/1`, `decode_response/1`, and optional parameter translation via `translate_options/3`.

See the [Adding a Provider Guide](guides/adding_a_provider.md) for detailed implementation instructions.

## Lower-Level Req Plugin API

For advanced use cases, you can use ReqLLM providers directly as Req plugins. This is the canonical implementation used by `ReqLLM.generate_text/3`:

```elixir
# The canonical pattern from ReqLLM.Generation.generate_text/3
with {:ok, model} <- ReqLLM.Model.from("anthropic:claude-3-sonnet"), # Parse model spec
     {:ok, provider_module} <- ReqLLM.provider(model.provider),        # Get provider module
     {:ok, request} <- provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7), # Build Req request
     {:ok, %Req.Response{body: response}} <- Req.request(request) do   # Execute HTTP request
  {:ok, response}
end

# Customize the Req pipeline with additional headers or middleware
{:ok, model} = ReqLLM.Model.from("anthropic:claude-3-sonnet")
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

1. Fork the repository
2. Create a feature branch  
3. Add tests for your changes
4. Run `mix quality` to ensure standards
5. Submit a pull request

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
