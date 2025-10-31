# API Reference

Complete reference for ReqLLM public API. Provides Vercel AI SDK-inspired functions with consistent signatures across streaming and non-streaming modes.

## Text Generation

### generate_text/3

Generate text using an AI model with full response metadata.

```elixir
@spec generate_text(model_spec, messages, opts) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
```

Returns a canonical ReqLLM.Response with usage data, context, and metadata.

**Examples:**
```elixir
# Simple text generation
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello world")
ReqLLM.Response.text(response)  # => "Hello! How can I assist you today?"

# With options
{:ok, response} = ReqLLM.generate_text(
  "anthropic:claude-haiku-4-5", 
  "Write a haiku",
  temperature: 0.8,
  max_tokens: 100
)

# Using context helper
ctx = ReqLLM.context([
  ReqLLM.Context.system("You are a helpful assistant"),
  ReqLLM.Context.user("What's 2+2?")
])
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", ctx)
```

### generate_text!/3

Generate text returning only the text content.

```elixir
@spec generate_text!(model_spec, messages, opts) :: String.t() | no_return()
```

**Examples:**
```elixir
ReqLLM.generate_text!("anthropic:claude-haiku-4-5", "Hello")
# => "Hello! How can I assist you today?"
```

### stream_text/3

Stream text generation with full response metadata.

```elixir
@spec stream_text(model_spec, messages, opts) :: {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
```

Returns a canonical ReqLLM.Response containing usage data and stream.

**Examples:**
```elixir
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Tell me a story")
ReqLLM.StreamResponse.tokens(response) |> Enum.each(&IO.write/1)

# Access usage after streaming
ReqLLM.Response.usage(response)
```

## Structured Data Generation

### generate_object/4

Generate structured data with schema validation.

```elixir
@spec generate_object(model_spec, messages, schema, opts) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
```

Equivalent to Vercel AI SDK's `generateObject()`. Supports three schema formats: NimbleOptions, JSON Schema, and Zoi.

**Schema Formats:**

```elixir
# NimbleOptions format (recommended)
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true],
  email: [type: :string]
]

# JSON Schema format
schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "age" => %{"type" => "integer"}
  },
  "required" => ["name", "age"]
}

# Zoi schema format
schema = Zoi.object(%{
  name: Zoi.string() |> Zoi.required(),
  age: Zoi.number() |> Zoi.int() |> Zoi.positive() |> Zoi.required()
})
```

**Examples:**
```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]
{:ok, response} = ReqLLM.generate_object("anthropic:claude-haiku-4-5", "Generate a person", schema)
person = ReqLLM.Response.object(response)
# => %{name: "John Doe", age: 30}
```

### generate_object!/4

Generate structured data returning only the object.

```elixir
@spec generate_object!(model_spec, messages, schema, opts) :: term() | no_return()
```

**Examples:**
```elixir
schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!("anthropic:claude-haiku-4-5", "Generate a person", schema)
# => %{name: "John Doe", age: 30}
```

### stream_object/4

Stream structured data generation. Supports the same schema formats as `generate_object/4`.

```elixir
@spec stream_object(model_spec, messages, schema, opts) :: {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
```

**Examples:**
```elixir
schema = [items: [type: {:list, :string}, required: true]]
{:ok, response} = ReqLLM.stream_object("anthropic:claude-haiku-4-5", "List 5 cities", schema)
ReqLLM.StreamResponse.tokens(response) |> Enum.each(&IO.inspect/1)
```

### stream_object!/4

Stream structured data returning only the stream.

```elixir
@spec stream_object!(model_spec, messages, schema, opts) :: Stream.t() | no_return()
```

## Embedding Functions

### embed/3

Generate embeddings for single or multiple texts.

```elixir
@spec embed(model_spec, text, opts) :: {:ok, [float()]} | {:error, Splode.t()}
```

**Examples:**
```elixir
# Single text
{:ok, embedding} = ReqLLM.embed("openai:text-embedding-3-small", "Hello world")

# Multiple texts (same function)
{:ok, embeddings} = ReqLLM.embed("openai:text-embedding-3-small", ["Hello", "World"])
```

## Model Specification Formats

ReqLLM accepts flexible model specifications:

### String Format
```elixir
"provider:model"
"anthropic:claude-haiku-4-5"
"openai:gpt-4o"
"ollama:llama3"
```

### Tuple Format
```elixir
{:anthropic, "claude-3-sonnet-20240229", temperature: 0.7}
{:openai, "gpt-4o", max_tokens: 1000}
```

### Struct Format
```elixir
%ReqLLM.Model{
  provider: :anthropic,
  model: "claude-3-sonnet-20240229", 
  temperature: 0.7,
  max_tokens: 1000
}
```

## Common Options

### Generation Parameters
- `:temperature` - Controls randomness (0.0 to 2.0)
- `:max_tokens` - Maximum tokens to generate
- `:top_p` - Nucleus sampling parameter
- `:presence_penalty` - Penalize new tokens based on presence
- `:frequency_penalty` - Penalize new tokens based on frequency
- `:stop` - Stop sequences (string or list)

### Context and Tools
- `:system_prompt` - System message for the model
- `:context` - Conversation context as ReqLLM.Context
- `:tools` - List of tool definitions for function calling
- `:tool_choice` - Tool selection strategy (`:auto`, `:required`, specific tool)

### Provider Options
- `:provider_options` - Provider-specific options map

**Examples:**
```elixir
# Using context helper
ctx = ReqLLM.context("Hello")

{:ok, response} = ReqLLM.generate_text(
  "anthropic:claude-haiku-4-5",
  ctx,
  temperature: 0.8,
  max_tokens: 500,
  tools: [weather_tool]
)
```

## Error Handling

ReqLLM uses Splode-based structured errors:

### Error Types
- `ReqLLM.Error.Invalid.Provider` - Unknown provider
- `ReqLLM.Error.Invalid.Parameter` - Invalid parameters
- `ReqLLM.Error.Invalid.Schema` - Invalid schema definitions
- `ReqLLM.Error.Invalid.Message` - Invalid message structures
- `ReqLLM.Error.API.Request` - API request failures
- `ReqLLM.Error.API.Response` - Response parsing errors
- `ReqLLM.Error.Validation.Error` - Parameter validation failures

**Examples:**
```elixir
case ReqLLM.generate_text("invalid:model", "Hello") do
  {:ok, response} -> 
    handle_success(response)
    
  {:error, %ReqLLM.Error.Invalid.Provider{} = error} ->
    Logger.error("Unknown provider: #{error.message}")
    
  {:error, %ReqLLM.Error.API.Request{} = error} ->
    Logger.error("API request failed: #{error.message}")
    
  {:error, error} ->
    Logger.error("Generation failed: #{inspect(error)}")
end
```

## Helper Functions

### tool/1

Create tool definitions for function calling:

```elixir
weather_tool = ReqLLM.tool(
  name: "get_weather",
  description: "Get current weather for a location",
  parameter_schema: [
    location: [type: :string, required: true],
    units: [type: :string, default: "metric"]
  ],
  callback: {WeatherAPI, :fetch_weather}
)

{:ok, response} = ReqLLM.generate_text(
  "anthropic:claude-haiku-4-5",
  "What's the weather in Paris?",
  tools: [weather_tool]
)
```

### json_schema/2

Create JSON schemas for structured data:

```elixir
schema = ReqLLM.json_schema([
  name: [type: :string, required: true],
  age: [type: :integer]
])
```

### cosine_similarity/2

Calculate similarity between embedding vectors:

```elixir
similarity = ReqLLM.cosine_similarity(embedding1, embedding2)
# => 0.9487...
```

### context/1

Create conversation contexts:

```elixir
# From string
ctx = ReqLLM.context("Hello world")

# From message list
ctx = ReqLLM.context([
  ReqLLM.Context.system("You are helpful"),
  ReqLLM.Context.user("Hello")
])
```
