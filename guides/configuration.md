# Configuration

This guide covers all global configuration options for ReqLLM, including timeouts, connection pools, and runtime settings.

## Quick Reference

```elixir
# config/config.exs
config :req_llm,
  # HTTP timeouts (all values in milliseconds)
  receive_timeout: 120_000,          # Default response timeout
  stream_receive_timeout: 120_000,   # Streaming chunk timeout
  metadata_timeout: 120_000,         # Streaming metadata collection timeout
  thinking_timeout: 300_000,         # Extended timeout for reasoning models
  image_receive_timeout: 120_000,    # Image generation timeout

  # Streaming request transforms
  finch_request_adapter: MyApp.FinchAdapter,  # Module implementing ReqLLM.FinchRequestAdapter

  # Key management
  load_dotenv: true,                 # Auto-load .env files at startup

  # Telemetry
  telemetry: [payloads: :none],      # Request payload policy (:none or :raw)

  # Debugging
  debug: false                       # Enable verbose logging
```

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

Timeout for collecting streaming metadata (usage, finish_reason) after the stream completes. Long-running streams or slow providers may need more time.

```elixir
config :req_llm, metadata_timeout: 120_000
```

Per-request override:

```elixir
ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Hello", metadata_timeout: 60_000)
```

### `image_receive_timeout` (default: 120,000ms)

Extended timeout specifically for image generation operations, which can take longer than text generation.

```elixir
config :req_llm, image_receive_timeout: 180_000
```

## Connection Pool Configuration

ReqLLM uses Finch for HTTP connections. By default, HTTP/1-only pools are used due to a [known Finch issue with HTTP/2 and large request bodies](https://github.com/sneako/finch/issues/265).

### Default Configuration

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 8]
    }
  ]
```

### High-Concurrency Configuration

For applications making many concurrent requests:

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 32]
    }
  ]
```

### HTTP/2 Configuration (Advanced)

Use with caution—HTTP/2 pools may fail with request bodies larger than 64KB:

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

ReqLLM emits native `:telemetry` events for request lifecycle, reasoning lifecycle, and token usage. By default, those events are metadata-only:

```elixir
config :req_llm, telemetry: [payloads: :none]
```

To include sanitized request and response payloads on request lifecycle events:

```elixir
config :req_llm, telemetry: [payloads: :raw]
```

Per-request override:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", telemetry: [payloads: :raw])

ReqLLM.stream_text("openai:gpt-5-mini", "Hello", telemetry: [payloads: :raw])
```

Notes:

- Payload capture only applies to request lifecycle events. Reasoning events are always metadata-only.
- Thinking and reasoning text is redacted from payloads.
- Tools are summarized to stable metadata and binary attachments are reduced to byte and media summaries.
- Unknown payload shapes are recursively sanitized so opaque binaries are summarized instead of passed through.
- Embedding and audio operations stay summarized rather than emitting raw vectors or audio bytes.
- Requested and effective reasoning telemetry are tracked separately, so provider translation can be observed when a reasoning setting is dropped or rewritten.
- If callers provide conflicting reasoning controls, explicit disable signals win in the normalized telemetry snapshot.
- The default is `:none`, which is the safer choice for multi-tenant systems.

See the [Telemetry Guide](telemetry.md) for the event model and payload semantics.

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

## Example: Production Configuration

```elixir
# config/prod.exs
config :req_llm,
  receive_timeout: 120_000,
  stream_receive_timeout: 120_000,
  thinking_timeout: 300_000,
  metadata_timeout: 120_000,
  telemetry: [payloads: :none],
  load_dotenv: false,  # Use proper secrets management in production
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 16]
    }
  ]
```

## Example: Development Configuration

```elixir
# config/dev.exs
config :req_llm,
  receive_timeout: 60_000,
  debug: true,
  load_dotenv: true
```
