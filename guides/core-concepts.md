# Core Concepts

## ReqLLM's purpose

ReqLLM normalizes the many ways LLM providers model requests and responses into a small set of common data structures. You work with a single, canonical model for:
- specifying models across providers
- representing conversations (context and messages)
- handling tool calls
- consuming streaming and final results

For full type and field details, see the [Data Structures](data-structures.md) guide.

## What normalization means

- **One conversation model**: user/system/assistant messages with typed content parts (text, images, files, tool calls/results).
- **One model spec**: "provider:model" plus common options; provider-specific options are translated under the hood.
- **One streaming shape**: unified `StreamChunk` events for content, tool calls, and metadata across providers.
- **One response shape**: a `Response` that exposes text/object extraction and usage consistently.

## 1) Model specification

Models can be specified as:
- **String**: `"provider:model"` (e.g., `"anthropic:claude-haiku-4-5"`)
- **Tuple**: `{:provider, "model", opt1: ..., opt2: ...}`
- **Struct**: `%ReqLLM.Model{...}`

Example:
```elixir
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")

# With options
{:ok, model} = ReqLLM.Model.from({:anthropic, "claude-3-5-sonnet",
  temperature: 0.7, max_tokens: 1000
})
```

**Normalization in practice**:
- Common options like `temperature` and `max_tokens` are normalized.
- Provider-specific options are translated by the provider adapter; you still pass them in one place.

## 2) Providers

Providers are plugins that translate between ReqLLM's canonical data structures and provider-specific HTTP APIs.
- You use the same API regardless of provider.
- Provider adapters handle request encoding, response decoding, streaming event conversion, and usage extraction.

You rarely need provider internals to build applications. If you author providers, see the [Adding a Provider](adding_a_provider.md) guide.

## 3) Context (conversations)

A `Context` is a list of `Message` structs. Each `Message` has a role and a list of typed `ContentPart` items. This uniform design enables multimodal conversations across providers.

Example:
```elixir
alias ReqLLM.Message.ContentPart

messages = [
  ReqLLM.Context.system("You are a helpful assistant."),
  ReqLLM.Context.user([
    ContentPart.text("Analyze this image:"),
    ContentPart.image_url("https://example.com/chart.png")
  ])
]
```

**Normalization in practice**:
- Same structure for text, image, and file inputs.
- No provider-specific message formats to learn.

## 4) Tool calls

Define tools once; invoke across providers with a unified call/result shape.
- Define tools with a name, description, and a `NimbleOptions` schema for validated arguments.
- Tool call requests and results appear as typed `ContentPart`s and `StreamChunk`s.

Example:
```elixir
tool = ReqLLM.Tool.new(
  name: "get_weather",
  description: "Gets weather by city",
  schema: [city: [type: :string, required: true]]
)

{:ok, response} =
  ReqLLM.generate_text("anthropic:claude-haiku-4-5",
    ReqLLM.Context.new([ReqLLM.Context.user("Weather in NYC today?")]),
    tools: [tool]
  )
```

## Next steps

Learn the canonical types in detail in the [Data Structures](data-structures.md) guide.
