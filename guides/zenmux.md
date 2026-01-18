# Zenmux

Enterprise-grade LLM aggregation platform with dual-protocol support (OpenAI and Anthropic compatible), intelligent routing, and insurance-backed quality guarantees.

## Configuration

```bash
ZENMUX_API_KEY=sk-ai-v1-...
```

## Provider Options

Passed via `:provider_options` keyword:

### Provider Routing

Configure multi-provider routing and failover strategies:

#### `provider`
- **Type**: Map
- **Purpose**: Advanced provider routing configuration
- **Structure**:
  ```elixir
  provider_options: [
    provider: %{
      routing: %{
        type: "priority",              # "priority" | "round_robin" | "least_latency"
        primary_factor: "cost",        # "cost" | "speed" | "quality"
        providers: ["openai", "anthropic", "google"]
      },
      fallback: "anthropic"            # true | false | specific provider name
    }
  ]
  ```
- **Routing Types**:
  - `"priority"`: Try providers in order with fallback
  - `"round_robin"`: Distribute requests evenly across providers
  - `"least_latency"`: Select fastest provider based on metrics
- **Primary Factors**:
  - `"cost"`: Prefer lower-cost providers
  - `"speed"`: Prefer faster-response providers
  - `"quality"`: Prefer higher-quality providers
- **Fallback**:
  - `true`: Enable automatic failover to any available provider
  - `false`: Disable failover (return error on failure)
  - `"provider_name"`: Specific fallback provider (e.g., `"anthropic"`)

### Model Routing

Configure model selection within the same provider:

#### `model_routing_config`
- **Type**: Map
- **Purpose**: Intelligent model selection based on task requirements
- **Structure**:
  ```elixir
  provider_options: [
    model_routing_config: %{
      available_models: ["openai/gpt-4o", "openai/gpt-4-turbo", "anthropic/claude-sonnet-4"],
      preference: "openai/gpt-4o",
      task_info: %{
        task_type: "chat",             # "chat" | "completion" | "embedding"
        complexity: "medium",          # "low" | "medium" | "high"
        additional_properties: %{}
      }
    }
  ]
  ```
- **Task Complexity**:
  - `"low"`: Simple tasks (short answers, basic rewrites)
  - `"medium"`: Moderate complexity (general Q&A, basic code)
  - `"high"`: Complex tasks (long documents, complex programming)

### Reasoning Configuration

#### `reasoning`
- **Type**: Map
- **Purpose**: Configure reasoning process behavior
- **Keys**:
  - `enable`: Boolean to enable/disable reasoning
  - `depth`: Control reasoning depth
  - `expose`: Whether to expose reasoning in response
- **Example**:
  ```elixir
  provider_options: [
    reasoning: %{
      enable: true,
      depth: "high",
      expose: true
    }
  ]
  ```

### Web Search

#### `web_search_options`
- **Type**: Map
- **Purpose**: Enable proactive web search for real-time information
- **Example**:
  ```elixir
  provider_options: [
    web_search_options: %{
      enabled: true,
      max_results: 5
    }
  ]
  ```

### Output Control

#### `max_completion_tokens`
- **Type**: Positive Integer
- **Purpose**: Maximum number of tokens to generate (including reasoning tokens).
- **Note**: Replaces `max_tokens`. If `max_tokens` is provided, it is automatically aliased to `max_completion_tokens`.
- **Example**: `max_completion_tokens: 4096`

#### `verbosity`
- **Type**: `"low"` | `"medium"` | `"high"`
- **Default**: `"medium"`
- **Purpose**: Control output detail level
- **Example**: `provider_options: [verbosity: "high"]`

#### `reasoning_effort`
- **Type**: `:none` | `:minimal` | `:low` | `:medium` | `:high` | `:xhigh`
- **Purpose**: Control reasoning model effort level
- **Example**: `provider_options: [reasoning_effort: :high]`

## Dual Protocol Support

Zenmux supports both OpenAI and Anthropic API protocols:

### OpenAI Protocol (Default)
```elixir
# Standard OpenAI-compatible endpoint
ReqLLM.generate_text("zenmux:openai/gpt-4o", "Hello!")
```

### Anthropic Protocol
For Anthropic-compatible tools and integrations, use the Anthropic base URL:
```elixir
# Configure with Anthropic protocol endpoint
model = ReqLLM.Model.new(
  provider: :zenmux,
  id: "anthropic/claude-sonnet-4.5",
  base_url: "https://zenmux.ai/api/anthropic"
)

ReqLLM.generate_text(model, "Hello!")
```

## Usage Examples

### Basic Text Generation
```elixir
{:ok, response} = ReqLLM.generate_text(
  "zenmux:openai/gpt-4o",
  "What is the capital of France?"
)
```

### Advanced Routing with Fallback
```elixir
{:ok, response} = ReqLLM.generate_text(
  "zenmux:openai/gpt-4o",
  "Complex analysis task",
  provider_options: [
    provider: %{
      routing: %{
        type: "priority",
        primary_factor: "quality",
        providers: ["openai", "anthropic", "google"]
      },
      fallback: "anthropic"
    }
  ]
)
```

### Model Selection by Task Complexity
```elixir
{:ok, response} = ReqLLM.generate_text(
  "zenmux:openai/gpt-4o",
  "Write a complex technical document",
  provider_options: [
    model_routing_config: %{
      available_models: ["openai/gpt-4o", "anthropic/claude-sonnet-4"],
      task_info: %{
        task_type: "completion",
        complexity: "high"
      }
    }
  ]
)
```

### Web Search Integration
```elixir
{:ok, response} = ReqLLM.generate_text(
  "zenmux:openai/gpt-4o",
  "What are the latest AI developments in 2026?",
  provider_options: [
    web_search_options: %{
      enabled: true,
      max_results: 10
    }
  ]
)
```

## Model Discovery

Browse available models:
- [Zenmux Models](https://zenmux.ai/models)
- Filter by protocol: OpenAI API Compatible or Anthropic API Compatible

## Key Benefits

- **Dual Protocol Support**: Compatible with both OpenAI and Anthropic SDKs
- **Enterprise Reliability**: High capacity reserves with automatic failover
- **Quality Assurance**: Regular degradation checks (HLE tests) with transparent results
- **AI Model Insurance**: Automated detection and payouts for quality issues
- **Intelligent Routing**: Optimize for cost, speed, or quality automatically
- **Global Edge Network**: Low-latency service via Cloudflare infrastructure
- **Single API Key**: Access all providers with unified billing

## Pricing

Transparent usage-based pricing with unified billing:
```elixir
{:ok, response} = ReqLLM.generate_text("zenmux:openai/gpt-4o", "Hello")
IO.puts("Cost: $#{response.usage.total_cost}")
IO.puts("Tokens: #{response.usage.total_tokens}")
```

## Resources

- [Zenmux Documentation](https://docs.zenmux.ai)
- [Model List](https://zenmux.ai/models)
- [Benchmarks](https://zenmux.ai/benchmark)
- [API Reference](https://docs.zenmux.ai/api/openai/create-chat-completion-new)
