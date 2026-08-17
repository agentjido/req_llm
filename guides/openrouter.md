# OpenRouter

Unified API for hundreds of AI models from multiple providers with intelligent routing and fallback.

## Configuration

```bash
OPENROUTER_API_KEY=sk-or-...
```

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Use exact OpenRouter model IDs from [LLM Catalog](https://llmcatalog.dev) when possible. If you need to route to a model that is not in the registry yet, use `ReqLLM.model!/1` and provide the full explicit model spec.

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

### Usage & Plugins

#### `openrouter_usage`
- **Type**: Map
- **Purpose**: Configure usage reporting
- **Example**: `provider_options: [openrouter_usage: %{include: true}]`

#### `openrouter_plugins`
- **Type**: List of maps
- **Purpose**: Enable OpenRouter plugins (e.g., web search)
- **Example**: `provider_options: [openrouter_plugins: [%{id: "web"}]]`

#### File parser PDFs

ReqLLM encodes PDF `ContentPart.file/3` inputs in OpenRouter's file format. The `file-parser` plugin is optional. Use it to select a PDF processing engine:

```elixir
alias ReqLLM.Context
alias ReqLLM.Message.ContentPart

context = Context.new([
  Context.user([
    ContentPart.text("Summarize this PDF."),
    ContentPart.file(pdf_bytes, "paper.pdf", "application/pdf")
  ])
])

ReqLLM.generate_text("openrouter:anthropic/claude-sonnet-4-20250514", context,
  provider_options: [openrouter_plugins: [%{id: "file-parser"}]]
)
```

Without `file-parser`, ReqLLM uses the same file encoding and lets OpenRouter select the PDF processing engine.

### Safety Settings (Google Models)

#### `openrouter_safety_settings`
- **Type**: List of maps
- **Purpose**: Set Google's per-category content filters on Gemini models routed through OpenRouter
- **Example**: `provider_options: [openrouter_safety_settings: [%{category: "HARM_CATEGORY_HARASSMENT", threshold: "OFF"}]]`

OpenRouter forwards the top-level `safety_settings` body field to Google, so the
same categories and thresholds accepted by the Gemini API apply here. This works
on both of OpenRouter's Google upstreams (`google-ai-studio` and `google-vertex`).

```elixir
safety_settings =
  Enum.map(
    ~w(HARM_CATEGORY_HARASSMENT HARM_CATEGORY_HATE_SPEECH
       HARM_CATEGORY_SEXUALLY_EXPLICIT HARM_CATEGORY_DANGEROUS_CONTENT),
    &%{category: &1, threshold: "BLOCK_ONLY_HIGH"}
  )

ReqLLM.generate_text("openrouter:google/gemini-2.5-flash", "Write a battle scene.",
  provider_options: [openrouter_safety_settings: safety_settings]
)
```

The option is ignored by non-Google models.

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

## Citations (Search Models)

Models that cite their sources — Perplexity Sonar in particular — return
`url_citation` annotations. OpenRouter speaks the OpenAI Chat Completions wire
format, so ReqLLM normalizes those citations the same way it does for OpenAI and
exposes them through `ReqLLM.Response.annotations/1`:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openrouter:perplexity/sonar",
  "What is a hello world program?"
)

ReqLLM.Response.annotations(response)
#=> [
#=>   %{
#=>     "type" => "url_citation",
#=>     "url" => "https://en.wikipedia.org/wiki/Hello,_world",
#=>     "title" => "Hello, world - Wikipedia",
#=>     "start_index" => 0,
#=>     "end_index" => 0
#=>   }
#=> ]
```

The nested `"url_citation"` wrapper OpenRouter sends on the wire is flattened, so
the shape matches what the direct OpenAI provider returns. Streaming works the
same way — citations accumulate across deltas and the materialized response carries
the full list. See [Citations](openai.md#citations) in the OpenAI guide for the
full contract, including how to consume citations live during a stream.

## Model Discovery

Browse available models:
- [OpenRouter Models](https://openrouter.ai/models)
- Model metadata is provided by the `llm_db` dependency

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
