# Core Concepts

ReqLLM = Req (HTTP) + Provider Plugins (format) + Canonical Data Model

## Data Model

```
ReqLLM.Model          # Model configuration with metadata
    ↓
ReqLLM.Context        # Collection of conversation messages  
    ↓
ReqLLM.Message        # Individual messages with typed content
    ↓
ReqLLM.Message.ContentPart  # Text, images, files, tool calls
    ↓
ReqLLM.StreamChunk    # Unified streaming response format
    ↓
ReqLLM.Tool           # Function definitions with validation
```

### Model Abstraction

```elixir
%ReqLLM.Model{
  provider: :anthropic,
  model: "claude-3-5-sonnet",
  temperature: 0.7,
  max_tokens: 1000,
  
  # Capability metadata from models.dev
  capabilities: %{tool_call: true, reasoning: false},
  modalities: %{input: [:text, :image], output: [:text]},
  cost: %{input: 3.0, output: 15.0}
}
```

### Multimodal Content

```elixir
message = %ReqLLM.Message{
  role: :user,
  content: [
    ContentPart.text("Analyze this image and document:"),
    ContentPart.image_url("https://example.com/chart.png"),
    ContentPart.file(pdf_data, "report.pdf", "application/pdf"),
    ContentPart.text("What insights do you see?")
  ]
}
```

### Unified Streaming

```elixir
# Text content
%StreamChunk{type: :content, text: "Hello there!"}

# Reasoning tokens (for supported models)
%StreamChunk{type: :thinking, text: "Let me consider..."}

# Tool calls
%StreamChunk{type: :tool_call, name: "get_weather", arguments: %{location: "NYC"}}

# Metadata
%StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}}
```

## Plugin Architecture

Providers implement `ReqLLM.Provider` behavior with callbacks for request preparation and response parsing.

```elixir
defmodule ReqLLM.Providers.Anthropic do
  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :anthropic,
    base_url: "https://api.anthropic.com/v1",
    metadata: "priv/models_dev/anthropic.json",
    default_env_key: "ANTHROPIC_API_KEY",
    provider_schema: [
      api_version: [type: :string, default: "2023-06-01"]
    ]

  # DSL generates: metadata/0, provider_id/0, supported_provider_options/0

  @impl ReqLLM.Provider
  def prepare_request(operation, model, messages, opts) do
    # Configure operation-specific request
  end

  @impl ReqLLM.Provider  
  def attach(request, model, opts) do
    # Register encode_body and decode_response as Req steps
  end

  @impl ReqLLM.Provider
  def encode_body(context) do
    # Transform context to provider JSON format
  end

  @impl ReqLLM.Provider
  def decode_response(response) do
    # Parse API response to canonical format
  end
end
```

### Request Flow

```
User API Call
    ↓ ReqLLM.generate_text/3
Model Resolution
    ↓ ReqLLM.Model.from/1  
Provider Lookup
    ↓ ReqLLM.Provider.Registry.fetch/1
Request Creation
    ↓ Req.new/1
Provider Attachment  
    ↓ provider.attach/3 (registers decode_response as Req step)
HTTP Request
    ↓ Req.request/1 (decode_response step runs automatically)
Canonical Response
```

### Composable Middleware

```elixir
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")
{:ok, provider} = ReqLLM.provider(:anthropic)

request = Req.new()
|> Req.Request.append_request_steps(log_request: &log_request/1)
|> Req.Request.append_response_steps(cache_response: &cache/1)
|> provider.attach(model, [])

{:ok, response} = Req.request(request)
```

## Format Translation

### Context Encoding
- Provider callbacks handle canonical-to-provider request format
- Built-in defaults provide OpenAI-style encoding, providers can override

### Response Decoding  
- Provider callbacks handle provider-to-canonical response format
- Unified streaming chunks across all providers

## Req Integration

Transport vs Format separation:

**Transport (Req):**
- Connection pooling
- SSL/TLS 
- Streaming (SSE)
- Retries & error handling

**Format (ReqLLM):**
- Model validation
- Message normalization  
- Response standardization
- Usage extraction

### Generation Flow

```elixir
# API call
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

# Model resolution  
{:ok, model} = ReqLLM.Model.from("anthropic:claude-haiku-4-5")

# Provider lookup
{:ok, provider} = ReqLLM.provider(:anthropic)

# Request creation & attachment
request = Req.new() |> provider.attach(model, [])

# HTTP execution
{:ok, http_response} = Req.request(request) 

# Response parsing
{:ok, chunks} = provider.parse_response(http_response, model)
```

### Streaming Flow

```elixir
{:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Tell a story")
# Returns {:ok, %ReqLLM.StreamResponse{}}

# Streaming uses Finch directly (not Req)
# StreamServer GenServer manages SSE event parsing
# Provider's decode_sse_event/2 converts to StreamChunk structs

StreamResponse.stream(stream_response)
|> Stream.filter(&(&1.type == :content))
|> Stream.map(&(&1.text))
|> Stream.each(&IO.write/1)
|> Stream.run()
```

## Provider System

### Creating Providers

```elixir
defmodule ReqLLM.Providers.CustomProvider do
  @behaviour ReqLLM.Provider
  
  use ReqLLM.Provider.DSL,
    id: :custom,
    base_url: "https://api.custom.com",
    metadata: "priv/models_dev/custom.json"
    
  @impl ReqLLM.Provider
  def prepare_request(operation, model, data, opts) do
    # Create and configure request for operation type
  end
  
  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    # Register encode_body/decode_response steps
  end
end
```

### Integration Points

1. `ReqLLM.Provider` behavior with required callbacks:
   - `prepare_request/4` - Configure operation-specific requests
   - `attach/3` - Register Req pipeline steps
   - `encode_body/1` - Transform context to provider JSON
   - `decode_response/1` - Parse API responses
2. Optional streaming callbacks:
   - `attach_stream/4` - Build Finch streaming requests
   - `decode_sse_event/2` - Decode SSE events to StreamChunk
   - `extract_usage/2` - Extract usage/cost data
   - `translate_options/3` - Provider-specific parameter translation
3. Models.dev metadata for capabilities and pricing

## Testing

Capability-focused test suites with live/cached fixture support:

```elixir
defmodule CoreTest do
  use ReqLLM.Test.LiveFixture, provider: :anthropic
  use ExUnit.Case, async: true

  describe "generate_text/3" do
    test "basic response" do
      {:ok, response} =
        use_fixture(:anthropic, "core-basic", fn ->
          ReqLLM.generate_text("anthropic:claude-3-haiku", "Hello")
        end)

      assert %ReqLLM.Response{} = response
      assert ReqLLM.Response.text(response) =~ "Hello"
    end
  end
end
```

## Observability

Standard Req steps enable monitoring and debugging:

```elixir
request = Req.new()
|> Req.Request.append_request_steps(
  log_request: &log_request/1,
  trace_request: &add_trace_headers/1
)
|> Req.Request.append_response_steps(
  log_response: &log_response/1,
  extract_usage: &ReqLLM.Step.Usage.extract_usage/1
)

configured = provider.attach(request, model, [])
```
