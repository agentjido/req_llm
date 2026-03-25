# Data Structures

## Overview

ReqLLM's canonical data model is the foundation for provider-agnostic AI interactions. It normalizes provider differences by enforcing a small, consistent set of structs that represent models, conversations, tools, responses, and streaming.

## Hierarchy

```
LLMDB.Model           # Canonical model metadata struct used by ReqLLM
    ↓
ReqLLM.Context        # Conversation history
    ↓
ReqLLM.Message        # A turn in the conversation
    ↓
ReqLLM.Message.ContentPart  # Typed content (text, images, files, tool calls, results)
    ↓
ReqLLM.Tool           # Tool definitions (name, description, schema)
    ↓
ReqLLM.StreamChunk    # Streaming events (content, tool_call, thinking, meta)
    ↓
ReqLLM.Response       # Canonical final response with usage and helpers
    ↓
ReqLLM.StreamResponse # Streaming handle with helpers
```

## Design goals

- **Provider-agnostic**: One set of types works across Anthropic, OpenAI, Google, etc.
- **Typed and explicit**: Discriminated unions for content; consistent fields, no surprises.
- **Composable and immutable**: Build contexts and messages with simple, predictable APIs.
- **Extensible**: Metadata fields and new content types can be added without breaking shape.

## 1) LLMDB.Model

Represents a model choice for a specific provider plus optional routing and capability metadata.

**Typical fields**:
- `provider`: atom, e.g., `:anthropic`
- `id`: string, e.g., `"claude-haiku-4-5"`
- `provider_model_id`: optional provider-facing wire ID
- `base_url`: optional per-model endpoint metadata
- `capabilities`, `limits`, `modalities`, `cost`, `pricing`, `extra`: optional metadata (often sourced from LLMDB)

**Constructors**:
```elixir
{:ok, model} = ReqLLM.model("anthropic:claude-haiku-4-5")

model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

# Direct struct creation if you need full control
model = LLMDB.Model.new!(%{
  provider: :anthropic,
  id: "claude-3-5-sonnet-20241022",
  capabilities: %{tool_call: true},
  modalities: %{input: [:text, :image], output: [:text]},
  cost: %{input: 3.0, output: 15.0}
})
```

**How this supports normalization**:
- One way to specify models across providers.
- Common options are normalized; provider-specific options are translated by the provider adapter.
- See the [Model Specs](model-specs.md) guide for the full model-spec resolution rules and explicit model-specification path.

## 2) ReqLLM.Context

A conversation wrapper around a list of `Message` structs. Implements `Enumerable` and `Collectable` for ergonomic manipulation.

**Constructors and helpers**:
```elixir
import ReqLLM.Context
alias ReqLLM.Message.ContentPart

context = Context.new([
  system("You are a helpful assistant."),
  user("Summarize this document."),
  user([
    ContentPart.file(pdf_data, "report.pdf", "application/pdf")
  ])
])
```

**How this supports normalization**:
- One conversation format for all providers (no provider-specific role/content layouts).
- Multimodal content is embedded uniformly via `ContentPart`.

## 3) ReqLLM.Message

Represents one conversational turn with a role and a list of `ContentPart` items.

**Typical fields**:
- `role`: `:system` | `:user` | `:assistant` | `:tool` (when appropriate)
- `content`: list of `ContentPart`

**Examples**:
```elixir
alias ReqLLM.Message.ContentPart

msg = %ReqLLM.Message{
  role: :user,
  content: [ContentPart.text("Hello!")]
}
```

**How this supports normalization**:
- Every message has a uniform shape; multimodality is handled by `ContentPart` rather than provider-specific message types.

## 4) ReqLLM.Message.ContentPart

Typed content elements that compose a `Message`. Common variants:
- `text/1`: `ContentPart.text("...")`
- `text/2`: `ContentPart.text("...", metadata)` with metadata map
- `image_url/1`: `ContentPart.image_url("https://...")`
- `image_url/2`: `ContentPart.image_url("https://...", metadata)` with metadata
- `image/2`: `ContentPart.image(binary, "image/png")`
- `image/3`: `ContentPart.image(binary, "image/png", metadata)` with metadata
- `file/3`: `ContentPart.file(binary, "name.ext", "mime/type")`
- `thinking/1`: `ContentPart.thinking("...")` for models that expose reasoning tokens
- `tool_call/2`: `ContentPart.tool_call("name", %{arg: "value"})` for assistant-issued calls
- `tool_result/2`: `ContentPart.tool_result("tool_call_id", %{...})` for tool outputs

**Example**:
```elixir
parts = [
  ContentPart.text("Analyze:"),
  ContentPart.image_url("https://example.com/chart.png")
]
```

**Metadata field**:

The `metadata` field allows passing provider-specific attributes through to the wire format. Currently supported metadata keys:

- `cache_control`: Anthropic prompt caching control (e.g., `%{type: "ephemeral"}`)

```elixir
# Enable prompt caching for text content
cached_text = ContentPart.text(
  "Long system prompt to cache...",
  %{cache_control: %{type: "ephemeral"}}
)

# Enable prompt caching for images
cached_image = ContentPart.image_url(
  "https://example.com/large-diagram.png",
  %{cache_control: %{type: "ephemeral"}}
)

# Or with binary image data
cached_binary_image = ContentPart.image(
  image_data,
  "image/png",
  %{cache_control: %{type: "ephemeral"}}
)
```

**How this supports normalization**:
- Discriminated union eliminates polymorphism across providers.
- New content types can be added without changing the `Message` shape.
- Metadata enables provider-specific features without breaking the canonical model.

## 5) ReqLLM.Tool

Defines callable functions (aka "tools" or "function calling") with validation.

**Typical fields**:
- `name`: string
- `description`: string
- `parameter_schema`: `NimbleOptions`-based schema for argument validation
- `callback`: function or MFA tuple to execute the tool

**Example**:
```elixir
{:ok, tool} = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Gets weather by city",
  parameter_schema: [city: [type: :string, required: true]],
  callback: fn %{city: city} -> {:ok, "Weather in #{city}: sunny"} end
)

# Execute locally (e.g., after a model issues a tool_call)
{:ok, result} = ReqLLM.Tool.execute(tool, %{"city" => "NYC"})
```

**How this supports normalization**:
- One tool definition is used across providers that support function/tool calling.
- Tool calls/results appear in `ContentPart` and `StreamChunk` the same way for all providers.
- Structured tool results should be represented in the content body as JSON when
  they carry model-visible semantics like `%{ok: true, result: ...}` or
  `%{ok: false, error: ...}`. Message metadata can preserve the original native
  output for adapters and local consumers, but it should not be the only source
  of meaning for follow-up model turns.

## 6) ReqLLM.StreamChunk

Unified streaming event payloads emitted during `stream_text`.

**Common chunk types**:
- `:content` — text tokens or content fragments
- `:thinking` — reasoning tokens (if provider exposes them)
- `:tool_call` — a call intent with name and arguments
- `:meta` — metadata such as `finish_reason`, usage deltas, etc.

**Example**:
```elixir
%ReqLLM.StreamChunk{type: :content, text: "Hello"}
%ReqLLM.StreamChunk{type: :tool_call, name: "get_weather", arguments: %{city: "NYC"}}
%ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}}
```

**How this supports normalization**:
- All providers' streaming formats are mapped into this single, consistent event model.

## 7) ReqLLM.Response

Canonical final response returned by non-streaming calls (and available after streaming completes, when applicable).

**Typical fields and helpers**:
- `content`/`messages`: unified assistant output as Messages/ContentParts
- `usage`: normalized token/cost data when available
- helpers: `ReqLLM.Response.text/1`, `ReqLLM.Response.object/1`, `ReqLLM.Response.usage/1`

**Example**:
```elixir
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5",
  [ReqLLM.Context.user("Hello")]
)

text = ReqLLM.Response.text(response)
usage = ReqLLM.Response.usage(response)
```

### Usage Structure

The `usage` field contains normalized usage data with token counts, costs, and tool/image usage:

```elixir
%{
  # Token counts
  input_tokens: 150,
  output_tokens: 200,
  total_tokens: 350,
  reasoning_tokens: 0,        # For reasoning models (o1, o3, gpt-5)
  cached_tokens: 100,         # Cached input tokens
  cache_creation_tokens: 0,   # Tokens used to create cache

  # Cost breakdown (USD)
  input_cost: 0.00045,
  output_cost: 0.0006,
  total_cost: 0.00105,

  # Detailed cost by category
  cost: %{
    tokens: 0.00105,
    tools: 0.02,              # Web search, function calls
    images: 0.0,              # Image generation
    total: 0.02105,
    line_items: [...]         # Per-component cost details
  },

  # Tool usage (web search, etc.)
  tool_usage: %{
    web_search: %{count: 2, unit: "call"}
  },

  # Image usage (for image generation)
  image_usage: %{
    generated: %{count: 1, size_class: "1024x1024"}
  }
}
```

See the [Usage & Billing Guide](usage-and-billing.md) for comprehensive documentation.

**How this supports normalization**:
- One response object to extract text, structured objects, and usage across providers.

## 8) ReqLLM.StreamResponse

Handle for streaming operations with helpers to consume chunks or tokens.

**Example**:
```elixir
{:ok, sr} = ReqLLM.stream_text("anthropic:claude-haiku-4-5",
  [ReqLLM.Context.user("Tell me a story")]
)

# Stream raw chunks
ReqLLM.StreamResponse.stream(sr)
|> Stream.each(fn chunk ->
  case chunk.type do
    :content -> IO.write(chunk.text)
    :tool_call -> IO.inspect(chunk, label: "Tool call")
    :meta -> :ok
    _ -> :ok
  end
end)
|> Stream.run()

# Or tokens helper (if available)
ReqLLM.StreamResponse.tokens(sr)
|> Stream.each(&IO.write/1)
|> Stream.run()
```

**How this supports normalization**:
- Same streaming consumption API for every provider; adapters convert SSE/WS specifics into `StreamChunk`.

## 9) Validation and type safety

ReqLLM provides validation utilities so you can fail early and clearly:
- `ReqLLM.Context.validate/1`
- `ReqLLM.StreamChunk.validate/1`
- Tool argument validation via `NimbleOptions` schemas

**Example**:
```elixir
case ReqLLM.Context.validate(context) do
  {:ok, ctx} -> ReqLLM.generate_text(model, ctx)
  {:error, reason} -> raise ArgumentError, "Invalid context: #{reason}"
end
```

## 10) End-to-end example (provider-agnostic)

```elixir
alias ReqLLM.Message.ContentPart

{:ok, model} = ReqLLM.model("anthropic:claude-haiku-4-5")

{:ok, tool} = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Gets weather by city",
  parameter_schema: [city: [type: :string, required: true]],
  callback: fn %{city: city} -> {:ok, "Weather in #{city}: sunny"} end
)

context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are a helpful assistant."),
  ReqLLM.Context.user([
    ContentPart.text("What is the weather in NYC today?")
  ])
])

{:ok, response} = ReqLLM.generate_text(model, context, tools: [tool])

IO.puts("Answer: " <> ReqLLM.Response.text(response))
IO.inspect(ReqLLM.Response.usage(response), label: "Usage")
```

**How this supports normalization**:
- At no point does your application code need to branch on provider.
- Providers translate request/response specifics into these canonical types.

## Key takeaways

- The canonical data structures are the heart of ReqLLM's "normalize everything" approach.
- Build contexts, messages, and tools once; reuse them across providers.
- Consume streaming and final results through a single, consistent API.
