# OpenAI Provider Guide

The OpenAI provider supports GPT models including GPT-4, GPT-3.5, and reasoning models like o1, o3, and GPT-5.

## Configuration

Set your OpenAI API key:

```bash
# Add to .env file (automatically loaded)
OPENAI_API_KEY=sk-...
```

Or use in-memory storage:

```elixir
ReqLLM.put_key(:openai_api_key, "sk-...")
```

## Dual API Architecture

OpenAI provider uses two specialized APIs:

### Chat Completions API (ChatAPI)

For standard GPT models:
- `gpt-4o`
- `gpt-4o-mini`
- `gpt-4-turbo`
- `gpt-3.5-turbo`

### Responses API (ResponsesAPI)

For reasoning models with extended thinking:
- `o1`, `o1-mini`, `o1-preview`
- `o3`, `o3-mini`
- `o4`-mini`
- `gpt-4.1`, `gpt-5`

ReqLLM automatically routes to the correct API based on model metadata.

## Basic Usage

```elixir
# Standard chat model
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "Explain async/await in JavaScript"
)

# Reasoning model
{:ok, response} = ReqLLM.generate_text(
  "openai:o1",
  "Solve this complex math problem step by step"
)

# Access reasoning tokens for reasoning models
reasoning_tokens = response.usage.reasoning_tokens
```

## Provider-Specific Options

### Embedding Dimensions

Control dimensions for embedding models:

```elixir
{:ok, embedding} = ReqLLM.embed(
  "openai:text-embedding-3-small",
  "Hello world",
  provider_options: [dimensions: 512]
)
```

### Encoding Format

Specify format for embedding output:

```elixir
{:ok, embedding} = ReqLLM.embed(
  "openai:text-embedding-3-small",
  "Hello world",
  provider_options: [encoding_format: "base64"]
)
```

### Max Completion Tokens

Required for reasoning models (o1, o3, gpt-5):

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:o1",
  "Complex problem",
  provider_options: [max_completion_tokens: 4000]
)
```

**Note**: Reasoning models use `max_completion_tokens` instead of `max_tokens`. ReqLLM handles this translation automatically when you use `max_tokens`.

### Structured Output Mode

Control how structured outputs are generated:

```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :integer, required: true]
]

{:ok, response} = ReqLLM.generate_object(
  "openai:gpt-4o",
  "Generate a person",
  schema,
  provider_options: [openai_structured_output_mode: :json_schema]
)
```

Modes:
- `:auto` - Use `json_schema` when supported, else strict tools (default)
- `:json_schema` - Force `response_format` with `json_schema` (requires model support)
- `:tool_strict` - Force `strict: true` on function tools

### Response Format

Custom response format configuration:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "Return JSON",
  provider_options: [
    response_format: %{
      type: "json_schema",
      json_schema: %{
        name: "person",
        schema: %{type: "object", properties: %{name: %{type: "string"}}}
      }
    }
  ]
)
```

### Parallel Tool Calls

Control parallel tool call behavior:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "What's the weather in NYC and LA?",
  tools: [weather_tool],
  provider_options: [openai_parallel_tool_calls: false]
)
```

### Reasoning Effort (Responses API Only)

Control reasoning effort for o1/o3/GPT-5 models:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:o1",
  "Difficult problem",
  provider_options: [reasoning_effort: :high]
)
```

Levels: `:minimal`, `:low`, `:medium`, `:high`

### Seed for Reproducibility

Set seed for deterministic outputs:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "Random story",
  provider_options: [seed: 42]
)
```

### Logprobs

Request log probabilities:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "Hello",
  provider_options: [
    logprobs: true,
    top_logprobs: 3
  ]
)
```

### User Identifier

Track usage by user:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "Hello",
  provider_options: [user: "user_123"]
)
```

## Streaming

```elixir
{:ok, stream_response} = ReqLLM.stream_text(
  "openai:gpt-4o",
  "Write a story"
)

# Stream tokens in real-time
ReqLLM.StreamResponse.tokens(stream_response)
|> Stream.each(&IO.write/1)
|> Stream.run()

# Get usage after streaming completes
usage = ReqLLM.StreamResponse.usage(stream_response)
```

## Tool Calling

```elixir
tools = [
  ReqLLM.tool(
    name: "get_weather",
    description: "Get weather for a location",
    parameter_schema: [
      location: [type: :string, required: true]
    ],
    callback: {WeatherAPI, :fetch}
  )
]

{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  "What's the weather in Seattle?",
  tools: tools
)
```

## Embeddings

```elixir
# Single embedding
{:ok, embedding} = ReqLLM.embed(
  "openai:text-embedding-3-small",
  "Hello world"
)

# Multiple texts
{:ok, embeddings} = ReqLLM.embed(
  "openai:text-embedding-3-small",
  ["Hello", "World", "Elixir"]
)
```

## Vision (Multimodal)

```elixir
import ReqLLM.Context
alias ReqLLM.Message.ContentPart

context = Context.new([
  user([
    ContentPart.text("Describe this image"),
    ContentPart.image_url("https://example.com/photo.jpg")
  ])
])

{:ok, response} = ReqLLM.generate_text("openai:gpt-4o", context)
```

## Complete Example

```elixir
import ReqLLM.Context

context = Context.new([
  system("You are a helpful coding assistant"),
  user("Explain tail recursion in Elixir")
])

{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-4o",
  context,
  temperature: 0.7,
  max_tokens: 500,
  provider_options: [
    seed: 42,
    logprobs: true,
    top_logprobs: 2
  ]
)

text = ReqLLM.Response.text(response)
usage = response.usage

IO.puts(text)
IO.puts("Cost: $#{usage.total_cost}")
```

## Reasoning Models Example

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:o1",
  "Solve: If a train travels 120 km in 2 hours, how far will it travel in 5 hours at the same speed?",
  max_tokens: 2000,  # Automatically translated to max_completion_tokens
  provider_options: [reasoning_effort: :medium]
)

# Reasoning models use thinking tokens
IO.puts("Reasoning tokens: #{response.usage.reasoning_tokens}")
IO.puts("Output tokens: #{response.usage.output_tokens}")
```

## Usage Metrics

OpenAI models provide comprehensive usage data:

```elixir
%{
  input_tokens: 10,
  output_tokens: 50,
  reasoning_tokens: 100,  # For reasoning models (o1, o3, gpt-5)
  cached_tokens: 5,       # Cached input tokens
  total_tokens: 60,
  input_cost: 0.00005,
  output_cost: 0.00075,
  total_cost: 0.0008
}
```

## Error Handling

```elixir
case ReqLLM.generate_text("openai:gpt-4o", "Hello") do
  {:ok, response} -> 
    handle_success(response)
    
  {:error, error} -> 
    IO.puts("Error: #{error.message}")
end
```

## Resources

- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference)
- [Model Overview](https://platform.openai.com/docs/models)
- [Pricing](https://openai.com/pricing)
