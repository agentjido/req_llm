# Anthropic

Access Claude models through ReqLLM's unified interface. Supports all Claude 3+ models including extended thinking.

## Configuration

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

## Provider Options

Passed via `:provider_options` keyword:

### `anthropic_top_k`
- **Type**: `1..40`
- **Purpose**: Sample from top K options per token
- **Example**: `provider_options: [anthropic_top_k: 20]`

### `anthropic_version`
- **Type**: String
- **Default**: `"2023-06-01"`
- **Purpose**: API version override
- **Example**: `provider_options: [anthropic_version: "2023-06-01"]`

### `stop_sequences`
- **Type**: List of strings
- **Purpose**: Custom stop sequences
- **Example**: `provider_options: [stop_sequences: ["END", "STOP"]]`

### `anthropic_metadata`
- **Type**: Map
- **Purpose**: Request metadata for tracking
- **Example**: `provider_options: [anthropic_metadata: %{user_id: "123"}]`

### `thinking`
- **Type**: Map
- **Purpose**: Enable extended thinking/reasoning
- **Example**: `provider_options: [thinking: %{type: "enabled", budget_tokens: 4096}]`
- **Access**: `ReqLLM.Response.thinking(response)`

### `anthropic_prompt_cache`
- **Type**: Boolean
- **Purpose**: Enable prompt caching
- **Example**: `provider_options: [anthropic_prompt_cache: true]`

### `anthropic_prompt_cache_ttl`
- **Type**: String (e.g., `"1h"`)
- **Purpose**: Cache TTL (default ~5min if omitted)
- **Example**: `provider_options: [anthropic_prompt_cache_ttl: "1h"]`

### `anthropic_cache_messages`
- **Type**: Boolean or Integer
- **Purpose**: Add cache breakpoint at a specific message position
- **Requires**: `anthropic_prompt_cache: true`
- **Values**:
  - `-1` or `true` - last message
  - `-2` - second-to-last, `-3` - third-to-last, etc.
  - `0` - first message, `1` - second, etc.
- **Examples**:
  ```elixir
  # Cache entire conversation (breakpoint at last message)
  provider_options: [anthropic_prompt_cache: true, anthropic_cache_messages: true]

  # Cache up to second-to-last message (before final user input)
  provider_options: [anthropic_prompt_cache: true, anthropic_cache_messages: -2]

  # Cache only up to first message
  provider_options: [anthropic_prompt_cache: true, anthropic_cache_messages: 0]
  ```

> **Note**: With `anthropic_prompt_cache: true`, system messages and tools are cached by default.
> Use `anthropic_cache_messages` to also cache conversation history. The offset applies to
> the messages array (user, assistant, and tool results), not system messages.
>
> **Lookback limit**: Anthropic only checks up to 20 blocks before each cache breakpoint.
> If you have many tools or long system prompts, consider where you place message breakpoints.

## Wire Format Notes

- Endpoint: `/v1/messages`
- Auth: `x-api-key` header (not Bearer token)
- System messages: included in messages array
- Tool calls: content block structure

All differences handled automatically by ReqLLM.

## Resources

- [Anthropic API Docs](https://docs.anthropic.com/claude/reference/getting-started-with-the-api)
- [Model Comparison](https://docs.anthropic.com/claude/docs/models-overview)
