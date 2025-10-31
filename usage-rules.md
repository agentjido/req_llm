# ReqLLM Usage Rules

ReqLLM provides two API layers for AI interactions: high-level convenience functions and low-level Req plugin access.

## High-Level API

### Text Generation

```elixir
# Simple text generation
ReqLLM.generate_text!("anthropic:claude-haiku-4-5", "Hello world")
#=> "Hello! How can I assist you today?"

# With full response metadata
{:ok, response} = ReqLLM.generate_text("openai:gpt-4", "Hello", temperature: 0.7)
response.usage  #=> %{input_tokens: 8, output_tokens: 12, total_cost: 0.0006}
```

### Streaming

```elixir
# New API returns StreamResponse struct
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Write a story")
response.stream
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Note: stream_text! is deprecated, use stream_text/3 instead
```

### Structured Objects

```elixir
schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!("openai:gpt-4", "Generate a person", schema)
#=> %{name: "John Doe", age: 30}
```

### Tools

```elixir
weather_tool = ReqLLM.tool(
  name: "get_weather",
  description: "Get current weather for a location",
  parameter_schema: [location: [type: :string, required: true]],
  callback: {WeatherAPI, :fetch_weather}
)

ReqLLM.generate_text("openai:gpt-4", "What's the weather in Paris?", tools: [weather_tool])
```

### Context & Messages

```elixir
context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are a helpful coding assistant"),
  ReqLLM.Context.user("Explain recursion in Elixir")
])

{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", context)
```

### Model Specifications

```elixir
# String format
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

# Tuple format with options
ReqLLM.generate_text({:anthropic, "claude-3-sonnet-20240229", temperature: 0.7}, "Hello")

# Model struct
model = %ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet-20240229", max_tokens: 100}
ReqLLM.generate_text(model, "Hello")
```

### Key Management

```elixir
# Keys auto-loaded from .env files via dotenvy at startup
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...

# Optional: Store in application config
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.get_key(:openai_api_key)

# Per-request override
ReqLLM.generate_text("openai:gpt-4", "Hello", api_key: "sk-...")
```

## Low-Level API

### Non-Streaming Requests

Direct Req plugin access for custom HTTP control:

```elixir
# Canonical implementation from ReqLLM.Generation.generate_text/3
with {:ok, model} <- ReqLLM.Model.from("anthropic:claude-haiku-4-5"),
     {:ok, provider_module} <- ReqLLM.provider(model.provider),
     {:ok, request} <- provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7),
     {:ok, %Req.Response{body: response}} <- Req.request(request) do
  {:ok, response}
end

# Custom headers and middleware
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")
{:ok, provider_module} = ReqLLM.provider(model.provider)
{:ok, request} = provider_module.prepare_request(:chat, model, "Hello!")

custom_request = 
  request
  |> Req.Request.put_header("x-request-id", "my-id")
  |> Req.Request.put_header("x-source", "my-app")

{:ok, response} = Req.request(custom_request)
```

### Streaming Requests

**IMPORTANT**: Streaming uses Finch, not Req. The `prepare_request/4` and `attach/3` callbacks do NOT work for streaming operations.

For custom streaming, use the provider's `attach_stream/4` callback or use `ReqLLM.Streaming.start_stream/4`:

```elixir
# High-level streaming API (recommended)
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Hello")
response.stream |> Stream.each(&IO.write(&1.text)) |> Stream.run()

# Low-level streaming (for advanced use cases)
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")
{:ok, provider_module} = ReqLLM.provider(model.provider)
context = ReqLLM.Context.new("Hello!")

{:ok, stream_response} = ReqLLM.Streaming.start_stream(
  provider_module,
  model,
  context,
  timeout: 60_000
)

stream_response.stream
|> Stream.each(&IO.write(&1.text))
|> Stream.run()
```

## Error Handling

```elixir
case ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello") do
  {:ok, response} -> response.text
  {:error, %ReqLLM.Error.API.RateLimit{retry_after: seconds}} -> 
    :timer.sleep(seconds * 1000)
  {:error, %ReqLLM.Error.API.Authentication{}} -> 
    {:error, :auth_failed}
  {:error, error} -> 
    {:error, :unknown}
end
```

## Essential Options

- `:temperature` - Randomness (0.0-2.0)
- `:max_tokens` - Response length limit
- `:tools` - Function calling definitions
- `:system_prompt` - System message
- `:provider_options` - Provider-specific parameters
- `:api_key` - Override stored key
