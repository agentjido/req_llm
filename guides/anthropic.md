# Anthropic

Access Claude models through ReqLLM's unified interface. Supports all Claude 3+ models including extended thinking.

## Configuration

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Use exact Claude IDs from [LLMDB.xyz](https://llmdb.xyz) when possible. If you need to call a new Claude release before it lands in LLMDB, build a full explicit model spec with `ReqLLM.model!/1`.

### OAuth Access Token (optional)

If your Anthropic setup uses OAuth, pass an access token and set auth mode:

```elixir
ReqLLM.generate_text(
  "anthropic:claude-sonnet-4-5",
  "Summarize this",
  auth_mode: :oauth,
  access_token: System.fetch_env!("ANTHROPIC_ACCESS_TOKEN")
)
```

You can also pass these under `provider_options`.

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

### `web_search`

- **Type**: Map
- **Purpose**: Enable web search tool with real-time web content access
- **Supported Models**: Claude Sonnet 4.5, Claude Sonnet 4, Claude Haiku 4.5, Claude Haiku 3.5, Claude Opus 4.5, Claude Opus 4.1, Claude Opus 4
- **Configuration Options**:
  - `max_uses` - Integer limiting the number of searches per request
  - `allowed_domains` - List of domains to include in results (e.g., `["wikipedia.org", "britannica.com"]`)
  - `blocked_domains` - List of domains to exclude from results (e.g., `["untrustedsource.com"]`)
  - `user_location` - Map with keys: `:type`, `:city`, `:region`, `:country`, `:timezone` for localized results
- **Pricing**: $10 per 1,000 searches plus standard token costs
- **Examples**:

  ```elixir
  # Basic web search with usage limit
  provider_options: [web_search: %{max_uses: 5}]

  # Web search with domain filtering
  provider_options: [
    web_search: %{
      max_uses: 3,
      allowed_domains: ["wikipedia.org", "britannica.com"]
    }
  ]

  # Web search with blocked domains
  provider_options: [
    web_search: %{
      blocked_domains: ["untrustedsource.com"]
    }
  ]

  # Web search with user location for localized results
  provider_options: [
    web_search: %{
      max_uses: 5,
      user_location: %{
        type: "approximate",
        city: "San Francisco",
        region: "California",
        country: "US",
        timezone: "America/Los_Angeles"
      }
    }
  ]

  # Combine with regular tools
  ReqLLM.chat(
    "What's the weather in NYC and latest tech news?",
    model: "anthropic:claude-sonnet-4-5",
    tools: [my_weather_tool],
    provider_options: [web_search: %{max_uses: 3}]
  )
  ```

> **Note**: Web search must be enabled by your organization administrator in the Anthropic Console.
> Domain filters cannot expand beyond organization-level restrictions. Claude automatically decides
> when to use web search and cites sources in its responses.

#### Web Search Cost Tracking

Web search usage and costs are tracked in `response.usage`:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "anthropic:claude-sonnet-4-5",
  "What are the latest AI announcements?",
  provider_options: [web_search: %{max_uses: 5}]
)

# Access web search usage
response.usage.tool_usage.web_search
#=> %{count: 2, unit: "call"}

# Access cost breakdown
response.usage.cost
#=> %{tokens: 0.001, tools: 0.02, images: 0.0, total: 0.021}
```

Web search is billed at **$10 per 1,000 searches** plus standard token costs.

## Wire Format Notes

- Endpoint: `/v1/messages`
- Auth: `x-api-key` header (not Bearer token)
- System messages: included in messages array
- Tool calls: content block structure

All differences handled automatically by ReqLLM.

## Resources

- [Anthropic API Docs](https://docs.anthropic.com/claude/reference/getting-started-with-the-api)
- [Model Comparison](https://docs.anthropic.com/claude/docs/models-overview)
