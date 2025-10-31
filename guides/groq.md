# Groq

Ultra-fast LLM inference with custom hardware (LPU). OpenAI-compatible with Groq-specific options.

## Configuration

```bash
GROQ_API_KEY=gsk_...
```

## Provider Options

Passed via `:provider_options` keyword:

### `service_tier`
- **Type**: `"auto"` | `"on_demand"` | `"flex"` | `"performance"`
- **Default**: `"auto"`
- **Purpose**: Control performance tier for requests
- **Example**: `provider_options: [service_tier: "performance"]`

### `reasoning_effort`
- **Type**: `"none"` | `"default"` | `"low"` | `"medium"` | `"high"`
- **Purpose**: Control reasoning level for compatible models
- **Compatible**: DeepSeek R1 distill models
- **Example**: `provider_options: [reasoning_effort: "high"]`

### `reasoning_format`
- **Type**: String
- **Purpose**: Specify format for reasoning output
- **Example**: `provider_options: [reasoning_format: "detailed"]`

### `search_settings`
- **Type**: Map
- **Purpose**: Enable web search capabilities
- **Keys**:
  - `include_domains`: List of domains to include
  - `exclude_domains`: List of domains to exclude
- **Example**:
  ```elixir
  provider_options: [
    search_settings: %{
      include_domains: ["techcrunch.com", "arstechnica.com"],
      exclude_domains: ["spam.com"]
    }
  ]
  ```

### `compound_custom`
- **Type**: Map
- **Purpose**: Custom configuration for Compound systems
- **Example**: `provider_options: [compound_custom: %{...}]`

## Performance Notes

- **Streaming**: Groq's LPU hardware excels at streaming - tokens appear instantly
- **Model Selection**: Use `8b-instant` for speed, `70b` for quality
- **Service Tier**: Use `"performance"` for lowest latency
- **Concurrency**: Handles concurrent requests efficiently

## Resources

- [Groq Documentation](https://console.groq.com/docs)
- [Model Playground](https://console.groq.com/playground)
