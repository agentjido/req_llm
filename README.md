# ReqLLM

[![Hex.pm](https://img.shields.io/hexpm/v/req_llm.svg)](https://hex.pm/packages/req_llm)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/req_llm/)
[![CI](https://github.com/agentjido/req_llm/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/req_llm/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/req_llm.svg)](https://github.com/agentjido/req_llm/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> **Join the community!** Come chat about building AI tools with Elixir and coding Elixir with LLMs in [The Swarm: Elixir AI Collective](https://jido.run/discord) Discord server.

A [Req](https://github.com/wojtekmach/req)- and [Finch](https://github.com/sneako/finch)-backed package to call LLM APIs that standardizes requests and responses across providers.

## Why Req LLM?

LLM APIs are inconsistent. ReqLLM provides a unified, idiomatic Elixir interface with standardized requests and responses across providers.

**Unified architecture:**

- **High-level API** – Vercel AI SDK-inspired functions (`generate_text/3`, `stream_text/3`, `generate_object/4` and more) that normalize requests and responses across providers.
- **Provider transports** – Req powers request/response calls; Finch powers streaming. Provider callbacks translate model metadata, options, bodies, and responses behind the same public API.

**Model Support Snapshot**

ReqLLM currently exposes **1,205 models across 21 implemented provider integrations** from [LLMDB](https://llmdb.xyz), the model catalog maintained through `llm_db`. Counting the cataloged-but-not-separate `google_vertex_anthropic` namespace, the registry contains **1,218 models across 22 provider namespaces**.

That breadth extends well beyond chat: ReqLLM tracks **92 non-text operation models** across embedding, image generation, text-to-speech, transcription, rerank, and OCR APIs. The fixture suite currently contains **622 unique recorded model specs**, giving ReqLLM a compatibility ledger for text and multi-modal provider behavior.

| Provider | ID | Catalog models | Operation surface | Recorded specs | Guide |
|---|---|---:|---|---:|---|
| [Alibaba Cloud Bailian](https://llmdb.xyz/?providers=alibaba) | `alibaba` | 50 | text, OCR 1, transcription 1 | 0 | — |
| [Alibaba Cloud Bailian (China)](https://llmdb.xyz/?providers=alibaba_cn) | `alibaba_cn` | 82 | text, OCR 1, transcription 1 | 0 | — |
| [Amazon Bedrock](https://llmdb.xyz/?providers=amazon_bedrock) | `amazon_bedrock` | 92 | text, embedding 3 | 7 | [Guide](guides/amazon_bedrock.md) |
| [Anthropic](https://llmdb.xyz/?providers=anthropic) | `anthropic` | 11 | text | 11 | [Guide](guides/anthropic.md) |
| [Azure OpenAI](https://llmdb.xyz/?providers=azure) | `azure` | 103 | text, embedding 6 | 26 | [Guide](guides/azure.md) |
| [Cerebras](https://llmdb.xyz/?providers=cerebras) | `cerebras` | 5 | text | 2 | [Guide](guides/cerebras.md) |
| [Cohere](https://llmdb.xyz/?providers=cohere) | `cohere` | 17 | text, rerank 5 | 5 | — |
| [ElevenLabs](https://llmdb.xyz/?providers=elevenlabs) | `elevenlabs` | 4 | speech 4 | 4 | — |
| [Fireworks AI](https://llmdb.xyz/?providers=fireworks_ai) | `fireworks_ai` | 12 | text | 12 | [Guide](guides/fireworks_ai.md) |
| [Google Gemini](https://llmdb.xyz/?providers=google) | `google` | 50 | text, embedding 2, image 8 | 24 | [Guide](guides/google.md) |
| [Google Vertex AI](https://llmdb.xyz/?providers=google_vertex) | `google_vertex` | 40 | text | 11 | [Guide](guides/google_vertex.md) |
| [Groq](https://llmdb.xyz/?providers=groq) | `groq` | 18 | text, speech 2, transcription 2 | 11 | [Guide](guides/groq.md) |
| [Meta Model API](https://llmdb.xyz/?providers=meta) | `meta` | 1 | text | 1 | [Guide](guides/meta.md) |
| [MiniMax](https://llmdb.xyz/?providers=minimax) | `minimax` | 6 | text | 6 | — |
| [Moonshot AI](https://llmdb.xyz/?providers=moonshotai) | `moonshotai` | 1 | text | 1 | [Guide](guides/moonshot_ai.md) |
| [OpenAI](https://llmdb.xyz/?providers=openai) | `openai` | 86 | text, embedding 3, image 5, speech 6, transcription 7 | 64 | [Guide](guides/openai.md) |
| [OpenRouter](https://llmdb.xyz/?providers=openrouter) | `openrouter` | 364 | text, embedding 25, image 5 | 234 | [Guide](guides/openrouter.md) |
| [Venice](https://llmdb.xyz/?providers=venice) | `venice` | 67 | text | 67 | — |
| [xAI](https://llmdb.xyz/?providers=xai) | `xai` | 26 | text, image 3 | 21 | [Guide](guides/xai.md) |
| [Z.AI](https://llmdb.xyz/?providers=zai) | `zai` | 13 | text | 2 | [Guide](guides/zai.md) |
| [Z.AI Coder](https://llmdb.xyz/?providers=zai_coder) | `zai_coder` | 5 | text | 1 | [Guide](guides/zai_coder.md) |
| [Z.AI Coding Plan](https://llmdb.xyz/?providers=zai_coding_plan) | `zai_coding_plan` | 5 | text | 4 | — |
| [Zenmux](https://llmdb.xyz/?providers=zenmux) | `zenmux` | 149 | text, image 2 | 107 | [Guide](guides/zenmux.md) |

\* _Streaming uses Finch directly due to known Req limitations with SSE responses._

## Installation

### Igniter Installation (Recommended)

The fastest way to get started is with [Igniter](https://hex.pm/packages/igniter):

```bash
mix igniter.install req_llm
```

### Manual Installation

Add `req_llm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:req_llm, "~> 1.6"}
  ]
end
```

Then run:

```bash
mix deps.get
```

### Optional Provider Dependencies

Two providers rely on external authentication libraries that are **optional** —
they are not pulled in unless you add them yourself, so most users incur no extra
dependencies:

| Provider | Add to `deps` | Used for |
| --- | --- | --- |
| `amazon_bedrock` | `{:ex_aws_auth, "~> 1.4"}` | AWS Signature V4 request signing (IAM credentials, STS, bidirectional streaming) |
| `google_vertex` | `{:goth, "~> 1.4"}` | Google Cloud OAuth via Application Default Credentials, refresh tokens, workload identity, and the metadata server |

If you use one of these providers without the corresponding dependency, ReqLLM
raises a clear error telling you which package to add. (Amazon Bedrock's API-key
auth and Google Vertex's service-account JWT signing do not require these
libraries.)

## Quick Start

```elixir
# Keys are picked up from .env files or environment variables - see `ReqLLM.Keys`
model = "anthropic:claude-haiku-4-5"

ReqLLM.generate_text!(model, "Hello world")
#=> "Hello! How can I assist you today?"

schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!(model, "Generate a person", schema)
#=> %{name: "John Doe", age: 30}

output = ReqLLM.Output.array([name: [type: :string, required: true]])
{:ok, response} = ReqLLM.generate_text(model, "Generate three people", output: output)
ReqLLM.Response.output(response, output)
#=> [%{"name" => "Ada"}, %{"name" => "Grace"}, %{"name" => "Linus"}]

result = ReqLLM.Response.output_result(response, output)
result.valid?       #=> true
result.raw          # retained text or tool-call arguments
result.repairs      # visible legacy or callback repair attempts

{:ok, strict_response} = ReqLLM.generate_text(
  model,
  "Generate three people",
  output: output,
  output_validation: :strict
)

{:ok, image_response} = ReqLLM.generate_image("openai:gpt-image-1.5", "A simple red square")
image_bytes = ReqLLM.Response.image_data(image_response)
File.write!("red_square.png", image_bytes)
```

Note: Google image models gemini-2.5-flash-image and gemini-3-pro-image-preview reject :n; specify the image count in the prompt.

```elixir
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
  - 21 implemented providers / 1,205 models sourced from [LLMDB](https://llmdb.xyz) via the `llm_db` dependency
  - Text, embedding, image generation, speech, transcription, rerank and OCR operation metadata
  - Cost, context length, modality, capability and deprecation metadata included

- **Canonical data model**
  - Typed `Context`, `Message`, `ContentPart`, `Tool`, `StreamChunk`, `Response`, `Usage`
  - Multi-modal content parts (text, image URL, tool call, binary)
  - All structs implement `Jason.Encoder` for simple persistence / inspection

- **Unified client surface**
  - High-level Vercel-AI style helpers (`generate_text/3`, `stream_text/3`, `generate_object/4`, bang variants)
  - Req-backed request/response calls and Finch-backed streaming behind the same provider abstraction
  - Advanced Req request customization available for non-streaming use cases

- **Structured output generation**
  - `ReqLLM.Output` descriptors add text, object, array, choice, and arbitrary JSON contracts to `generate_text/3` and `stream_text/3`
  - `generate_object/4` and `stream_object/4` remain compatible object-generation conveniences
  - Zero-copy mapping to provider JSON-schema / function-calling endpoints
  - OpenAI native structured outputs with three modes (`:auto` (default), `:json_schema`, `:tool_strict`)

- **Provider-specific capabilities**
  - Anthropic web search for real-time content access (via `provider_options: [web_search: %{max_uses: 5}]`)
  - Extended thinking/reasoning for supported models
  - Prompt caching for cost optimization
  - All provider-specific options documented in provider guides

- **Embedding generation**
  - Single or batch embeddings via `Embedding.generate/3` (Not all providers support this)
  - Automatic dimension / encoding validation and usage accounting

- **Production-grade streaming**
  - `stream_text/3` returns a `StreamResponse` with both real-time tokens and async metadata
  - Finch-based streaming with automatic connection pooling and configurable checkout timeouts
  - OpenAI Responses models can opt into WebSocket mode with `provider_options: [openai_stream_transport: :websocket]`
  - Concurrent metadata collection (usage, finish_reason) without blocking token flow
  - Works uniformly across providers with internal SSE / chunked-response adaptation

- **Experimental OpenAI realtime sessions**
  - `ReqLLM.OpenAI.Realtime` exposes a low-level WebSocket session API for Realtime models
  - Designed for explicit event-driven workflows that do not map cleanly to `stream_text/3`

- **Usage & cost tracking**
  - `response.usage` exposes normalized usage and best-effort USD cost from model metadata and provider response data

- **Schema-driven option validation**
  - All public APIs validate options with NimbleOptions; errors are raised as `ReqLLM.Error.Invalid.*` (Splode)

- **Automatic parameter translation & codecs**
  - Provider DSL translates canonical options (e.g. `max_tokens` -> `max_completion_tokens` for o1 & o3) to provider-specific names
  - Built-in OpenAI-style encoding/decoding with provider callback overrides for custom formats

- **Flexible model specification**
  - Accepts `"provider:model"`, tuples, `%LLMDB.Model{}` structs, and plain-map model specs
  - `ReqLLM.model!/1` is the recommended way to validate and normalize full model specs

- **Secure, layered key management** (`ReqLLM.Keys`)
  - Per-request override → application config → env vars / .env files
- **OAuth bearer auth for supported providers**
  - Direct `access_token` support for OpenAI and Anthropic
  - OpenAI can load and refresh `openai-codex` credentials from `oauth.json` / `auth.json`
  - `openai_codex:*` targets the ChatGPT Codex backend with OAuth-only auth and automatic account-id extraction

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

By default, ReqLLM loads `.env` files from the current working directory at startup. To disable this behavior (e.g., if you manage environment variables yourself):

```elixir
config :req_llm, load_dotenv: false
```

## Model Specs

ReqLLM can call models that are not in LLMDB yet. This is the recommended advanced
workflow for local development, debugging new releases, and custom provider setups.

See the [Model Specs](guides/model-specs.md) guide for the full explanation of
string specs, exact dated releases, `%LLMDB.Model{}` structs, and the full explicit
model specification path.

For backwards compatibility, you can pass a plain map directly to the major APIs.
The clearer path is to normalize it first with `ReqLLM.model!/1`, which returns an
enriched `%LLMDB.Model{}`.

```elixir
model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Hello world")
```

You can still pass the plain-map model spec directly:

```elixir
ReqLLM.generate_text!(
  %{provider: :openai, id: "gpt-6-mini", base_url: "http://localhost:8000/v1"},
  "Hello world"
)
```

Use additional metadata only when the provider needs it:

```elixir
model =
  ReqLLM.model!(%{
    provider: :google_vertex,
    id: "zai-org/glm-4.7-maas",
    extra: %{family: "glm"}
  })
```

ReqLLM hard-fails early when the model spec is missing required routing data, with
errors aimed at advanced users:

- Inline models always need `provider` and `id` (or `model`)
- Azure still needs a `base_url`
- Google Vertex MaaS models may need `extra.family` when the model family cannot be inferred

## Usage Cost Tracking

Every response includes detailed usage and best-effort cost information calculated from normalized provider usage data plus model pricing metadata:

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

ReqLLM treats pricing as an observability and estimation feature, not an invoice guarantee. When provider billing accuracy matters, compare these values against your own provider-side reporting. See the [Pricing Policy](guides/pricing-policy.md) guide for the full contract and known limitations.

### Tool & Image Usage

When using web search or generating images, additional usage metadata is available:

```elixir
# Web search usage (Anthropic, OpenAI, xAI, Google)
{:ok, response} = ReqLLM.generate_text(model, prompt,
  provider_options: [web_search: %{max_uses: 5}])

response.usage.tool_usage
#=> %{web_search: %{count: 2, unit: "call"}}

response.usage.cost
#=> %{tokens: 0.001, tools: 0.02, images: 0.0, total: 0.021}

# Image generation usage
{:ok, response} = ReqLLM.generate_image("openai:gpt-image-1.5", prompt)

response.usage.image_usage
#=> %{generated: %{count: 1, size_class: "1024x1024"}}
```

A native ReqLLM telemetry surface is published for every request, including streaming:

- `[:req_llm, :request, :start | :stop | :exception]` for lifecycle timing, summaries, and usage
- `[:req_llm, :reasoning, :start | :update | :stop]` for standardized thinking and reasoning milestones
- `[:req_llm, :token_usage]` for backwards-compatible token and cost measurements

All events share a `request_id` so you can correlate request lifecycle, reasoning lifecycle, and billing data across providers.

For OpenTelemetry, attach `ReqLLM.OpenTelemetry` once to emit GenAI client spans, optional GenAI metrics, cost attributes, and Langfuse-friendly message capture.

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", content: :attributes, langfuse: true)
```

See `examples/scripts/usage_cost_search_image.exs` and run it from `examples/` with `mix run scripts/usage_cost_search_image.exs` for a multi-provider smoke test that validates search tool and image generation cost metadata. For comprehensive documentation, see the [Telemetry Guide](guides/telemetry.md) and [Usage & Billing Guide](guides/usage-and-billing.md).

## Streaming Configuration

ReqLLM uses Finch for streaming connections with automatic connection pooling. By default, we use HTTP/1-only pools to avoid a known Finch mixed-protocol ALPN bug with large request bodies:

```elixir
# Default configuration (automatic)
config :req_llm,
  stream_pool_timeout: 120_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 8
```

### HTTP/2 Configuration (Advanced)

**Important:** Due to [Finch issue #265](https://github.com/sneako/finch/issues/265), mixed HTTP/1+HTTP/2 ALPN pools may fail when sending request bodies larger than 64KB (large prompts, extensive context windows). This is a bug in Finch's mixed-protocol flow control path, not a limitation of HTTP/2 itself.

If you know all target providers support HTTP/2, you can configure HTTP/2-only pools:

```elixir
# HTTP/2-only configuration
config :req_llm,
  stream_pool_protocols: [:http2],
  stream_pool_count: 8
```

**ReqLLM will error with a helpful message if you try to send a large request body with mixed HTTP/1+HTTP/2 pools.** The error will reference this section for configuration guidance.

Streaming responses hold a connection until completion. For high-scale deployments, tune both the Finch pool capacity and the stream checkout timeout:

```elixir
# High-scale configuration
# config/runtime.exs
round_robin = Finch.Pool.Strategy.RoundRobin.new()

config :req_llm,
  stream_pool_timeout: 300_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 32,
  stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}
```

With the default HTTP/1 transport, concurrent streams per origin are roughly `stream_pool_size * stream_pool_count`. Prefer increasing `stream_pool_count` first when a single pool worker is under pressure; increase `stream_pool_size` when each worker should hold more concurrent HTTP/1 connections. For high worker counts, a round-robin `stream_pool_strategy` spreads stream starts more evenly than Finch's default random selection. These settings configure ReqLLM's default Finch pool; an explicit `finch: [pools: ...]` configuration takes precedence.

If you need origin-specific pools, HTTP/2, connection options, or pool metrics, configure Finch directly:

```elixir
# Advanced Finch configuration
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 32]
    }
  ]
```

Use `pool_timeout: ...` on an individual `stream_text/3` or `stream_object/4` call when one workload needs a longer connection checkout window than the global `stream_pool_timeout` setting.

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

ReqLLM uses OpenAI Chat Completions as the baseline API standard. Providers that support this format (like Groq, OpenRouter, xAI) require minimal overrides using the `ReqLLM.Provider.DSL`. Model metadata is automatically synced from [LLMDB](https://llmdb.xyz).

Providers implement the `ReqLLM.Provider` behavior with functions like `encode_body/1`, `decode_response/1`, and optional parameter translation via `translate_options/3`.

See the [Adding a Provider Guide](guides/adding_a_provider.md) for detailed implementation instructions.

## Advanced Req Plugin API

For advanced non-streaming use cases, you can use ReqLLM providers directly as Req plugins. This is the canonical implementation used by `ReqLLM.generate_text/3`:

```elixir
# The canonical pattern from ReqLLM.Generation.generate_text/3
with {:ok, model} <- ReqLLM.model("anthropic:claude-haiku-4-5"), # Parse model spec
     {:ok, provider_module} <- ReqLLM.provider(model.provider),        # Get provider module
     {:ok, request} <- provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7), # Build Req request
     {:ok, %Req.Response{body: response}} <- Req.request(request) do   # Execute HTTP request
  {:ok, response}
end

# Customize the Req pipeline with additional headers or middleware
{:ok, model} = ReqLLM.model("anthropic:claude-haiku-4-5")
{:ok, provider_module} = ReqLLM.provider(model.provider)
{:ok, request} = provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7)

# Add custom headers or middleware before sending
custom_request =
  request
  |> Req.Request.put_header("x-request-id", "my-custom-id")
  |> Req.Request.put_header("x-source", "my-app")

{:ok, response} = Req.request(custom_request)
```

This approach gives you full control over the Req pipeline, allowing you to add custom middleware, modify requests, or integrate with existing Req-based applications. Streaming uses Finch through `stream_text/3`.

## Documentation

- [Compatibility Policy](COMPATIBILITY.md) – stable, experimental, deprecated, platform, and ReqLLM/Jido contracts
- [Model Support Evidence](guides/model-support.md) – generated, surface-specific compatibility tiers
- [Getting Started](guides/getting-started.md) – first call and basic concepts
- [Configuration](guides/configuration.md) – timeouts, connection pools, and global settings
- [Telemetry](guides/telemetry.md) – request lifecycle, reasoning lifecycle, payload capture
- [Core Concepts](guides/core-concepts.md) – architecture & data model
- [Data Structures](guides/data-structures.md) – detailed type information
- [Host Integration](guides/host-integration.md) – stable one-call boundary for Jido and other hosts
- [Provider-native Integrations](guides/provider-native-integrations.md) – MCP, native tool, resource, and future operation boundaries
- [Pricing Policy](guides/pricing-policy.md) – cost-calculation scope, guarantees, and known gaps
- [Usage & Billing](guides/usage-and-billing.md) – token costs, tool usage, image costs
- [Image Generation](guides/image-generation.md) – generating images with OpenAI and Google
- [Mix Tasks](guides/mix-tasks.md) – model sync, compatibility testing, code generation
- [Fixture Testing](guides/fixture-testing.md) – model validation and supported models
- [Adding a Provider](guides/adding_a_provider.md) – extend with new providers
- Provider Guides: [Anthropic](guides/anthropic.md), [OpenAI](guides/openai.md), [Google](guides/google.md), [Google Vertex](guides/google_vertex.md), [xAI](guides/xai.md), [Groq](guides/groq.md), [OpenRouter](guides/openrouter.md), [Amazon Bedrock](guides/amazon_bedrock.md), [Azure](guides/azure.md), [Cerebras](guides/cerebras.md), [Fireworks AI](guides/fireworks_ai.md), [Meta](guides/meta.md), [Moonshot AI](guides/moonshot_ai.md), [Z.AI](guides/zai.md), [Z.AI Coder](guides/zai_coder.md), [Zenmux](guides/zenmux.md)

## Roadmap & Status

ReqLLM has reached v1.0.0. Its [compatibility policy](COMPATIBILITY.md)
protects the stable core API while the [roadmap](ROADMAP.md) evolves the library
through conservative V1 improvements and separately justified V2 candidates.
If you run into anything or have suggestions, please open an issue or PR.

### Test Coverage & Quality Commitment

ReqLLM uses fixture-backed compatibility tests as a practical map of provider behavior. The current suite includes **160 passing model-compat entries** across 13 providers and **622 unique recorded fixture model specs** across text, streaming, tool calling, structured output, embeddings, image generation, speech, transcription, rerank, and OCR.

Catalog support and fixture-verified coverage are tracked separately on purpose: provider catalogs move quickly, account access varies, and some modalities need specialized tests. ReqLLM makes that state visible through `mix mc "*:*"` and lets you narrow checks by provider or operation type when you need to validate the exact models your application uses.

**We welcome bug reports and feedback!** If you encounter issues with any supported model, please open a GitHub issue with details. The more feedback we receive, the stronger the code will be!

## Development

```bash
# Install dependencies
mix deps.get

# Run tests with cached fixtures
mix test

# Run quality checks
mix quality  # format, compile, credo --strict, dialyzer

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
