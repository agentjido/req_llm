# ReqLLM Usage Rules

This document provides best practices and guidelines for using ReqLLM effectively in Elixir applications.

## Core Purpose and Scope

ReqLLM is a composable library for AI interactions that normalizes LLM provider differences through a plugin-based architecture. It treats each provider as a Req plugin, handling format translation via a Codec protocol while leveraging Req's HTTP infrastructure.

Key concepts:
- **Provider Plugins**: Each AI provider (Anthropic, OpenAI) implements the `ReqLLM.Provider` behavior
- **Codec Protocols**: Translate between canonical structures and provider-specific formats
- **Model Specifications**: Flexible ways to specify models (string, tuple, struct)
- **StreamChunks**: Unified output format across all providers
- **Context/Message/ContentPart**: Provider-agnostic conversation structures

## Essential Usage Guidelines

### Model Specifications

**Best Practice**: Start with string format and graduate to struct format as needed.

```elixir
# Simple - good for basic usage
{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello")

# Advanced - good for complex configurations  
model = %ReqLLM.Model{
  provider: :anthropic,
  model: "claude-3-sonnet",
  temperature: 0.7,
  max_tokens: 1000
}
{:ok, response} = ReqLLM.generate_text(model, "Hello")
```

**Avoid**: Creating Model structs manually when string format suffices.

### API Function Selection

**Best Practice**: Use bang variants (`!`) for simple use cases, full functions for production.

```elixir
# Development/simple cases
ReqLLM.generate_text!("anthropic:claude-3-sonnet", "Hello")

# Production - need access to metadata, errors, usage data
{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello")
response.text()   #=> "Hello! How can I help?"
response.usage()  #=> %{input_tokens: 10, output_tokens: 8}
```

**Avoid**: Using bang variants when you need detailed error handling or usage tracking.

### Context and Message Construction

**Best Practice**: Import context helpers for clean message building.

```elixir
import ReqLLM.Context

context = Context.new([
  system("You are a helpful assistant"),
  user("What's 2+2?")
])

{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", context)
```

**Avoid**: Manually constructing Message structs when helpers exist.

### Multimodal Content

**Best Practice**: Import ContentPart helpers for clean multimodal handling.

```elixir
import ReqLLM.Message.ContentPart

message = ReqLLM.Context.user([
  text("Analyze this image"),
  image_url("https://example.com/chart.png")
])

{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", [message])
```

### Streaming

**Best Practice**: Filter StreamChunks by type for clean processing.

```elixir
{:ok, stream} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell a story")

# Collect only text content
text = stream
|> Stream.filter(&(&1.type == :text))
|> Stream.map(&(&1.text))
|> Enum.join()

# Handle different chunk types  
stream
|> Enum.each(fn chunk ->
  case chunk.type do
    :text -> IO.write(chunk.text)
    :tool_call -> handle_tool_call(chunk)
    :meta -> handle_metadata(chunk)
    _ -> :ok
  end
end)
```

### Error Handling

**Best Practice**: Pattern match on specific error types for appropriate handling.

```elixir
case ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello") do
  {:ok, response} -> 
    handle_success(response)
    
  {:error, %ReqLLM.Error.Invalid.Provider{}} ->
    Logger.error("Unsupported provider")
    {:error, :unsupported_provider}
    
  {:error, %ReqLLM.Error.API.RateLimit{retry_after: seconds}} ->
    Logger.warn("Rate limited, retry after #{seconds}s")
    :timer.sleep(seconds * 1000)
    retry_request()
    
  {:error, %ReqLLM.Error.API.Authentication{}} ->
    Logger.error("Authentication failed - check API key")
    {:error, :auth_failed}
    
  {:error, error} ->
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, :unknown}
end
```

## Configuration and Setup

### Key Management

**Important**: ReqLLM uses JidoKeys with automatic .env loading via Dotenvy.

```elixir
# Preferred - JidoKeys automatically loads from .env files
# No explicit setup needed if keys are in .env as:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...

# Optional manual key setup
ReqLLM.put_key("anthropic_api_key", System.get_env("ANTHROPIC_API_KEY"))
ReqLLM.put_key("openai_api_key", System.get_env("OPENAI_API_KEY"))

# Providers automatically retrieve keys via JidoKeys
{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello")
```

## Tool Calling

### Tool Definition

**Best Practice**: Define tools with comprehensive parameter schemas using NimbleOptions.

```elixir
weather_tool = ReqLLM.Tool.new!(
  name: "get_weather", 
  description: "Get current weather for a location",
  parameter_schema: [
    location: [type: :string, required: true, doc: "City name"],
    units: [type: :string, default: "celsius", doc: "Temperature units"]
  ],
  callback: {WeatherAPI, :fetch_weather}
)
```

### Tool Execution

**Best Practice**: Handle tool execution errors gracefully with proper return tuples.

```elixir
defmodule WeatherAPI do
  def fetch_weather(%{location: location, units: units}) do
    case HTTPClient.get("/weather", location: location, units: units) do
      {:ok, %{status: 200, body: data}} ->
        {:ok, data}
        
      {:ok, %{status: 404}} ->
        {:error, "Location not found"}
        
      {:error, reason} ->
        {:error, "Weather service unavailable: #{inspect(reason)}"}
    end
  rescue
    error ->
      {:error, "Weather fetch failed: #{Exception.message(error)}"}
  end
end
```

## Advanced Usage Patterns

### Custom Req Middleware

**Best Practice**: Use provider's `attach/3` with custom Req pipeline steps.

```elixir
def traced_generate_text(model_spec, messages, opts \\ []) do
  with {:ok, model} <- ReqLLM.Model.from(model_spec),
       {:ok, provider_module} <- ReqLLM.Provider.get(model.provider) do
    
    request = Req.new()
    |> provider_module.attach(model, opts)
    |> Req.Request.append_request_steps(tracing: &add_request_tracing/1)
    
    Req.request(request)
  end
end

defp add_request_tracing(request) do
  request_id = UUID.uuid4()
  %{request | 
    headers: [{"x-request-id", request_id} | request.headers],
    private: Map.put(request.private, :trace_id, request_id)
  }
end
```

### Usage Monitoring

**Best Practice**: Extract usage data from Response structs for monitoring.

```elixir
def monitored_generation(model_spec, messages, opts \\ []) do
  start_time = System.monotonic_time()
  
  case ReqLLM.generate_text(model_spec, messages, opts) do
    {:ok, response} ->
      duration = System.monotonic_time() - start_time
      
      Logger.info("LLM Generation", [
        model: inspect(model_spec),
        usage: response.usage(),
        duration_ms: System.convert_time_unit(duration, :native, :millisecond)
      ])
      
      {:ok, response.text()}
      
    {:error, error} ->
      Logger.error("LLM Generation failed: #{inspect(error)}")
      {:error, error}
  end
end
```

## Performance Considerations

### Memory Management

**Best Practice**: Process streams incrementally for large responses.

```elixir
{:ok, stream} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Write a long story")

stream
|> Stream.filter(&(&1.type == :text))
|> Stream.chunk_every(100)  # Process in chunks
|> Stream.each(&process_chunk/1)
|> Stream.run()
```

### Connection Reuse

**Important**: ReqLLM leverages Req's connection pooling automatically. Avoid creating new clients per request.

## Common Pitfalls

### Model Specification Errors

**Problem**: Using unsupported model names or invalid provider IDs.

**Solution**: Use `ReqLLM.Model.from/1` to validate specifications early.

```elixir
case ReqLLM.Model.from("invalid:model") do
  {:ok, model} -> proceed_with_model(model)
  {:error, error} -> 
    Logger.error("Invalid model spec: #{inspect(error)}")
    use_fallback_model()
end
```

### Stream Processing Issues

**Problem**: Assuming all stream chunks contain text data.

**Solution**: Always filter by chunk type before processing.

```elixir
# Safe stream processing
text_chunks = stream
|> Stream.filter(fn chunk -> chunk.type == :text and chunk.text != nil end)
|> Stream.map(&(&1.text))
```
