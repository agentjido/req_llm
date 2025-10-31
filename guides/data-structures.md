# Data Structures

## Overview

ReqLLM's canonical data model is the foundation for provider-agnostic AI interactions. It normalizes provider differences by enforcing a small, consistent set of structs that represent models, conversations, tools, responses, and streaming.

## Hierarchy

```
ReqLLM.Model          # Model configuration and metadata
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

## 1) ReqLLM.Model

Represents a model choice for a specific provider plus normalized options and optional metadata.

**Typical fields**:
- `provider`: atom, e.g., `:anthropic`
- `model`: string, e.g., `"claude-haiku-4-5"`
- `options`: `temperature`, `max_tokens`, etc.
- `capabilities`, `modalities`, `cost`: optional metadata (often sourced from models.dev)

**Constructors**:
```elixir
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")

{:ok, model} = ReqLLM.Model.from({:anthropic, "claude-3-5-sonnet",
  temperature: 0.7, max_tokens: 1000
})

# Direct struct creation if you need full control
model = %ReqLLM.Model{
  provider: :anthropic,
  model: "claude-3-5-sonnet",
  temperature: 0.3,
  max_tokens: 4000,
  capabilities: %{tool_call: true},
  modalities: %{input: [:text, :image], output: [:text]},
  cost: %{input: 3.0, output: 15.0}
}
```

**How this supports normalization**:
- One way to specify models across providers.
- Common options are normalized; provider-specific options are translated by the provider adapter.

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
- `image_url/1`: `ContentPart.image_url("https://...")`
- `image/2`: `ContentPart.image(binary, "image/png")`
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

**How this supports normalization**:
- Discriminated union eliminates polymorphism across providers.
- New content types can be added without changing the `Message` shape.

## 5) ReqLLM.Tool

Defines callable functions (aka "tools" or "function calling") with validation.

**Typical fields**:
- `name`: string
- `description`: string
- `schema`: `NimbleOptions`-based schema for argument validation

**Example**:
```elixir
tool = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Gets weather by city",
  schema: [city: [type: :string, required: true]]
)

# Execute locally (e.g., after a model issues a tool_call)
{:ok, result} = ReqLLM.Tool.execute(tool, %{city: "NYC"})
```

**How this supports normalization**:
- One tool definition is used across providers that support function/tool calling.
- Tool calls/results appear in `ContentPart` and `StreamChunk` the same way for all providers.

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

{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")

tool = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Gets weather by city",
  schema: [city: [type: :string, required: true]]
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
