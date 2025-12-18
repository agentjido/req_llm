# OpenRouter

Unified API for hundreds of AI models from multiple providers with intelligent routing and fallback.

## Configuration

```bash
OPENROUTER_API_KEY=sk-or-...
```

## Provider Options

Passed via `:provider_options` keyword:

### Model Routing

#### `openrouter_models`
- **Type**: List of strings
- **Purpose**: Specify fallback models for automatic routing
- **Example**:
  ```elixir
  provider_options: [
    openrouter_models: [
      "anthropic/claude-3.5-sonnet",
      "anthropic/claude-3-haiku",
      "openai/gpt-4o"
    ]
  ]
  ```

#### `openrouter_route`
- **Type**: String
- **Purpose**: Routing strategy (e.g., `"fallback"`)
- **Example**: `provider_options: [openrouter_route: "fallback"]`

#### `openrouter_provider`
- **Type**: Map
- **Purpose**: Provider preferences for routing
- **Keys**:
  - `order`: List of preferred providers
  - `require_parameters`: Boolean
- **Example**:
  ```elixir
  provider_options: [
    openrouter_provider: %{
      order: ["Together", "Fireworks"],
      require_parameters: true
    }
  ]
  ```

### Prompt Transforms

#### `openrouter_transforms`
- **Type**: List of strings
- **Purpose**: Apply transforms to prompts
- **Example**: `provider_options: [openrouter_transforms: ["middle-out"]]`

### Sampling Parameters

#### `openrouter_top_k`
- **Type**: Integer
- **Purpose**: Top-k sampling
- **Note**: Not available for all models (e.g., OpenAI models)
- **Example**: `provider_options: [openrouter_top_k: 40]`

#### `openrouter_repetition_penalty`
- **Type**: Float
- **Purpose**: Reduce repetitive text
- **Example**: `provider_options: [openrouter_repetition_penalty: 1.1]`

#### `openrouter_min_p`
- **Type**: Float
- **Purpose**: Minimum probability threshold for sampling
- **Example**: `provider_options: [openrouter_min_p: 0.05]`

#### `openrouter_top_a`
- **Type**: Float
- **Purpose**: Top-a sampling parameter
- **Example**: `provider_options: [openrouter_top_a: 0.1]`

#### `openrouter_top_logprobs`
- **Type**: Integer
- **Purpose**: Number of top log probabilities to return
- **Example**: `provider_options: [openrouter_top_logprobs: 5]`

### App Attribution

#### `app_referer`
- **Type**: String
- **Purpose**: HTTP-Referer header for app identification
- **Benefit**: App discoverability in OpenRouter rankings
- **Example**: `provider_options: [app_referer: "https://myapp.com"]`

#### `app_title`
- **Type**: String
- **Purpose**: X-Title header for app title
- **Benefit**: App ranking in OpenRouter
- **Example**: `provider_options: [app_title: "My Awesome App"]`

## Prompt Caching (Anthropic Models)

When using Anthropic models via OpenRouter, you can enable prompt caching by adding `cache_control` metadata to your `ContentPart` structs:

```elixir
alias ReqLLM.Message.ContentPart

# Create content with cache_control metadata
system_content = ContentPart.text(
  "You are a helpful assistant with extensive knowledge...",
  %{cache_control: %{type: "ephemeral"}}
)

# Use in a message
context = ReqLLM.Context.new([
  ReqLLM.Context.system([system_content]),
  ReqLLM.Context.user("Hello!")
])

# The cache_control will be passed through to Anthropic
{:ok, response} = ReqLLM.generate_text(
  "openrouter:anthropic/claude-sonnet-4-20250514",
  context
)
```

The `cache_control` metadata is passed directly to the underlying Anthropic API, enabling prompt caching for system prompts, tools, and message content.

> **Note**: This differs from the direct Anthropic provider which uses `anthropic_prompt_cache: true` option. Through OpenRouter, you have fine-grained control over exactly which content blocks get cached.

## Model Discovery

Browse available models:
- [OpenRouter Models](https://openrouter.ai/models)
- `mix req_llm.model_sync openrouter`

## Pricing

Dynamic pricing based on underlying provider. Check response usage:
```elixir
{:ok, response} = ReqLLM.generate_text("openrouter:model", "Hello")
IO.puts("Cost: $#{response.usage.total_cost}")
```

## Key Benefits

- Single API for multiple providers
- Automatic fallback routing
- Cost optimization through model selection
- No vendor lock-in

## Resources

- [OpenRouter Documentation](https://openrouter.ai/docs)
- [Model List](https://openrouter.ai/models)
