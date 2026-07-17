# Configuration

This guide covers all global configuration options for ReqLLM, including timeouts, connection pools, and runtime settings.

## Quick Reference

```elixir
# config/config.exs
config :req_llm,
  # HTTP timeouts (all values in milliseconds)
  receive_timeout: 120_000,          # Default response timeout
  stream_receive_timeout: 120_000,   # Streaming chunk timeout
  stream_pool_timeout: 120_000,      # Streaming connection checkout timeout
  stream_pool_protocols: [:http1],   # Default stream pool protocols
  stream_pool_size: 1,               # HTTP/1 connections per stream pool worker
  stream_pool_count: 8,              # Stream pool workers per origin
  stream_pool_strategy: nil,         # Finch shard selection strategy
  metadata_timeout: 120_000,         # Streaming metadata collection timeout
  thinking_timeout: 300_000,         # Extended timeout for reasoning models
  image_receive_timeout: 120_000,    # Image generation timeout

  # Streaming request transforms
  finch_request_adapter: MyApp.FinchAdapter,  # Module implementing ReqLLM.FinchRequestAdapter

  # Key management
  load_dotenv: true,                 # Auto-load .env files at startup

  # Telemetry
  telemetry: [payloads: :none],      # Request payload policy (:none or :raw)

  # Privacy
  redact_context: false,             # Hide message contents in inspect output

  # Debugging
  debug: false                       # Enable verbose logging
```

## Canonical Reasoning Options

ReqLLM accepts provider-neutral reasoning controls on text requests:

```elixir
ReqLLM.generate_text(
  "anthropic:claude-sonnet-4-5",
  "Solve this carefully",
  reasoning_effort: :high,
  reasoning_token_budget: 8_192
)
```

`reasoning_effort` accepts `:none`, `:minimal`, `:low`, `:medium`, `:high`,
`:xhigh`, and `:default`. `reasoning_token_budget` refines the request on
provider surfaces with an explicit thinking budget. Older `reasoning: true` and
string-valued `reasoning` aliases remain supported, but new code should use the
canonical options.

Provider-native controls such as Anthropic `thinking` and Google
`google_thinking_budget` remain available under `provider_options`. Avoid mixing
canonical and provider-native controls unless you rely on the provider's
existing precedence rules.

Lossy or ignored reasoning translations are non-fatal by default and emit a
deterministic warning. `ReqLLM.plan/3` reports the same sanitized warnings
without making a request. These reasoning advisories do not introduce new
failures for `on_unsupported: :error`; existing enforceable provider warnings
retain their current behavior.

## Provider Option Namespaces

ReqLLM 1.x accepts both the existing flat `provider_options` shape and an
additive provider-keyed shape. Existing calls remain valid and do not warn when
their flat options are unambiguous:

```elixir
ReqLLM.generate_text(
  "openai:gpt-5",
  "Solve this carefully",
  provider_options: [reasoning_summary: "auto"]
)
```

New code can scope the same options to the selected provider:

```elixir
ReqLLM.generate_text(
  "openai:gpt-5",
  "Solve this carefully",
  provider_options: [
    openai: [reasoning_summary: "auto"]
  ]
)
```

Keyword lists and atom-keyed maps are supported:

```elixir
provider_options: %{
  openai: %{reasoning_summary: "auto"}
}
```

The namespace is always the actual ReqLLM provider identity. Use `azure:` for
Azure-hosted models, `google_vertex:` for Vertex-hosted models, and
`openrouter:` for OpenRouter models. Do not use `openai:` or `google:` merely
because the hosted service uses an OpenAI- or Gemini-compatible wire format.
Foreign namespaces fail before network I/O.

When forms are combined, precedence is deterministic:

1. Explicit top-level canonical options win over the same namespaced option.
2. Options under the selected provider namespace win over colliding legacy flat
   provider options.
3. Non-colliding flat and namespaced provider options are merged.

Mixed forms emit an actionable warning by default. Set `on_unsupported: :error`
to reject an ambiguous mix, or `on_unsupported: :ignore` to apply the same
precedence without logging. Invalid namespace containers, unknown namespaced
options, duplicate namespaced keys, and foreign provider namespaces are rejected
before I/O. ReqLLM 1.x does not reject an otherwise valid call merely because it
uses the legacy flat shape.

## Timeout Configuration

ReqLLM uses multiple timeout settings to handle different scenarios:

### `receive_timeout` (default: 30,000ms)

The standard HTTP response timeout for non-streaming requests. Increase this for slow models or large responses.

```elixir
config :req_llm, receive_timeout: 60_000
```

Per-request override:

```elixir
ReqLLM.generate_text("openai:gpt-4o", "Hello", receive_timeout: 60_000)
```

### `stream_receive_timeout` (default: inherits from `receive_timeout`)

Timeout between streaming chunks. If no data arrives within this window, the stream fails.

```elixir
config :req_llm, stream_receive_timeout: 120_000
```

### `stream_pool_timeout` (when unset: inherits from `stream_receive_timeout`)

Timeout for checking out a Finch connection before a streaming request starts. Increase this when short bursts of concurrent streams can queue behind long-running responses.

```elixir
config :req_llm, stream_pool_timeout: 300_000
```

Per-request override:

```elixir
ReqLLM.stream_text(model, messages, pool_timeout: 300_000)
```

### `stream_pool_protocols` (default: `[:http1]`)

Protocols for ReqLLM's default Finch stream pool. Use HTTP/1 for broad provider compatibility, or HTTP/2-only when all target providers support HTTP/2.

```elixir
config :req_llm, stream_pool_protocols: [:http2]
```

Avoid mixed HTTP/1+HTTP/2 ALPN pools for large prompts. Due to a Finch flow-control issue, `[:http2, :http1]` and `[:http1, :http2]` may fail when request bodies exceed 64KB.

### `stream_pool_size` (default: 1)

Maximum HTTP/1 connections per stream pool worker. With the default HTTP/1 transport, concurrent streams per origin are roughly `stream_pool_size * stream_pool_count`.

```elixir
config :req_llm, stream_pool_size: 2
```

### `stream_pool_count` (default: 8)

Number of stream pool workers per origin. Increase this when high concurrent streaming load produces Finch checkout queue timeouts and the downstream provider can handle more simultaneous streams.

```elixir
config :req_llm, stream_pool_count: 32
```

### `stream_pool_strategy` (default: `nil`)

Finch shard selection strategy used when `stream_pool_count` is greater than 1. Finch defaults to random shard selection. Large streaming deployments can use round-robin to spread stream starts evenly across pool workers:

```elixir
# config/runtime.exs
round_robin = Finch.Pool.Strategy.RoundRobin.new()

config :req_llm,
  stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}
```

Per-request override:

```elixir
ReqLLM.stream_text(model, messages, pool_strategy: Finch.Pool.Strategy.Random)
```

These settings configure ReqLLM's default Finch pool. If you set `config :req_llm, finch: [pools: ...]`, that explicit Finch pool configuration takes precedence.

### `thinking_timeout` (default: 300,000ms / 5 minutes)

Extended timeout for reasoning models that "think" before responding (e.g., Claude with extended thinking, OpenAI o1/o3 models, Z.AI thinking mode). These models may take several minutes to produce the first token.

```elixir
config :req_llm, thinking_timeout: 600_000  # 10 minutes
```

**Automatic detection:** ReqLLM automatically applies `thinking_timeout` when:
- Extended thinking is enabled on Anthropic models
- Using OpenAI o1/o3 reasoning models
- Z.AI or Z.AI Coder thinking mode is enabled

### `metadata_timeout` (default: 300,000ms)

Maximum time without semantic stream progress while collecting metadata. Content, reasoning, tool, and usage events restart a finite timeout, so active long-running streams are not failed based on total elapsed time. Set it to `:infinity` to disable the inactivity timeout.

```elixir
config :req_llm, metadata_timeout: 120_000
```

Per-request override:

```elixir
ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Hello", metadata_timeout: 60_000)

ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Hello", metadata_timeout: :infinity)
```

### `image_receive_timeout` (default: 120,000ms)

Extended timeout specifically for image generation operations, which can take longer than text generation.

```elixir
config :req_llm, image_receive_timeout: 180_000
```

## Connection Pool Configuration

ReqLLM uses Finch for HTTP connections. By default, HTTP/1-only pools are used because Finch's mixed HTTP/1+HTTP/2 ALPN pools have a [known large-body flow-control issue](https://github.com/sneako/finch/issues/265).

Streaming responses hold a connection until the stream completes. With the default HTTP/1 configuration, each origin can run up to `size * count` concurrent checked-out connections before new streams wait in Finch's checkout queue.

### Default Configuration

```elixir
config :req_llm,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 8
```

### High-Concurrency Configuration

For applications making many concurrent requests:

```elixir
# config/runtime.exs
round_robin = Finch.Pool.Strategy.RoundRobin.new()

config :req_llm,
  stream_pool_timeout: 300_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 32,
  stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}
```

When this is not enough or when you need origin-specific settings, replace the full Finch pool configuration:

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 32]
    }
  ]
```

If you see `Finch was unable to provide a connection within the timeout due to excess queuing for connections`, tune both sides of the limit:

- Raise `stream_pool_timeout` when bursty workloads can safely wait for an existing stream to finish.
- Increase `stream_pool_count` or `stream_pool_size` when the downstream provider and your rate limits can handle more simultaneous streams.
- Add application-level concurrency limits when provider rate limits, costs, or latency make unbounded queueing unsafe.

For example, to allow roughly 32 concurrent HTTP/1 streams per provider origin:

```elixir
# config/runtime.exs
round_robin = Finch.Pool.Strategy.RoundRobin.new()

config :req_llm,
  stream_pool_timeout: 300_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 32,
  stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}
```

### HTTP/2 Configuration (Advanced)

Use HTTP/2-only when all target providers support HTTP/2:

```elixir
config :req_llm,
  stream_pool_protocols: [:http2],
  stream_pool_count: 8
```

Use mixed HTTP/1+HTTP/2 ALPN pools with caution. They may fail with request bodies larger than 64KB:

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http2, :http1], size: 1, count: 8]
    }
  ]
```

### Custom Finch Instance Per-Request

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages, finch_name: MyApp.CustomFinch)
```

## Streaming Request Transforms

ReqLLM provides two hooks for modifying a `Finch.Request` struct just before a streaming request is sent (to align with a similar ability present in `Req`) — useful for injecting headers, adding tracing metadata, or other environment-specific concerns.

### `finch_request_adapter` (config-level)

Set a module that implements the `ReqLLM.FinchRequestAdapter` behaviour. Because config files cannot hold anonymous functions, this mechanism requires a named module.

```elixir
# config/test.exs
config :req_llm, finch_request_adapter: MyApp.TestFinchAdapter
```

```elixir
defmodule MyApp.TestFinchAdapter do
  @behaviour ReqLLM.FinchRequestAdapter

  @impl true
  def call(%Finch.Request{} = request) do
    %{request | headers: request.headers ++ [{"x-test-env", "true"}]}
  end
end
```

### `on_finch_request` (per-request)

Pass an anonymous function `(Finch.Request.t() -> Finch.Request.t())` as a per-call option:

```elixir
ReqLLM.stream_text("openai:gpt-4o", "Hello",
  on_finch_request: fn req ->
    %{req | headers: req.headers ++ [{"x-request-id", UUID.generate()}]}
  end
)
```

### Precedence

Both mechanisms can be combined. The config-level adapter is applied first, then the per-request callback. Each step receives the output of the previous one.

## Telemetry Configuration

ReqLLM emits native `:telemetry` events for every request. The only application-level setting is the payload capture mode:

```elixir
config :req_llm, telemetry: [payloads: :none]   # default — metadata only
config :req_llm, telemetry: [payloads: :raw]    # include sanitized payloads
```

Raw payloads are sanitized (reasoning text redacted, binaries summarized, tools reduced to stable metadata) — `:none` is the safer default for multi-tenant systems.

Override per request via the `telemetry:` option:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", telemetry: [payloads: :raw])
```

See the [Telemetry Guide](telemetry.md) for the full event model, payload semantics, and the OpenTelemetry bridge.

## API Key Configuration

Keys are loaded with clear precedence: per-request → in-memory → app config → env vars → .env files.

### .env Files (Recommended)

```bash
# .env
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GOOGLE_API_KEY=...
```

Disable automatic .env loading:

```elixir
config :req_llm, load_dotenv: false
```

### Application Config

```elixir
config :req_llm,
  anthropic_api_key: "sk-ant-...",
  openai_api_key: "sk-..."
```

### Runtime / In-Memory

```elixir
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.put_key(:openai_api_key, "sk-...")
```

### Per-Request Override

```elixir
ReqLLM.generate_text("openai:gpt-4o", "Hello", api_key: "sk-...")
```

## Provider-Specific Configuration

Configure base URLs or other provider-specific settings:

```elixir
config :req_llm, :azure,
  base_url: "https://your-resource.openai.azure.com",
  api_version: "2024-08-01-preview"
```

See individual provider guides for available options.

## Debug Mode

Enable verbose logging for troubleshooting:

```elixir
config :req_llm, debug: true
```

Or via environment variable:

```bash
REQ_LLM_DEBUG=1 mix test
```

## Context Redaction

Hide message contents when a `Context` struct is inspected, preventing sensitive prompts or responses from leaking into logs:

```elixir
config :req_llm, redact_context: true
```

When enabled, `inspect/2` shows only the message count:

```elixir
inspect(context)
#=> "#Context<4 messages [REDACTED]>"
```

When disabled (the default), the full message preview is shown as normal:

```elixir
inspect(context)
#=> "#Context<2 msgs: system:\"You are a helpful assistant\", user:\"Hello\">"
```

## Example: Production Configuration

```elixir
# config/prod.exs
config :req_llm,
  receive_timeout: 120_000,
  stream_receive_timeout: 120_000,
  stream_pool_timeout: 120_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 16,
  stream_pool_strategy: nil,
  thinking_timeout: 300_000,
  metadata_timeout: 120_000,
  telemetry: [payloads: :none],
  load_dotenv: false  # Use proper secrets management in production
```

## Example: Development Configuration

```elixir
# config/dev.exs
config :req_llm,
  receive_timeout: 60_000,
  debug: true,
  load_dotenv: true
```
