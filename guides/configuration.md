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

  # Key management
  load_dotenv: true,                 # Auto-load .env files at startup

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
