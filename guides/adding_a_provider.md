# Adding a New Provider

## TL;DR

- Implement a provider module under `lib/req_llm/providers/`, use `ReqLLM.Provider.DSL` + `Defaults`, and only override what the API actually deviates on.
- The `Default` provider implementation is OpenAI Compatible.
- Non-streaming requests run through Req with `attach/3` + `encode_body/1` + `decode_response/1`; streaming runs through Finch with `attach_stream/4` + `decode_stream_event/2` or `/3`.
- Add models via `priv/models_local/`, run `mix req_llm.model_sync`, then add tests using the three-tier strategy and record fixtures with `LIVE=true`.

## Overview and Prerequisites

### What it means to add a provider

Adding a provider means implementing a single Elixir module that:

- Translates between canonical types (`Model`, `Context`, `Message`, `ContentPart`, `Tool`) and the provider HTTP API
- Implements the `ReqLLM.Provider` behavior via the DSL and default callbacks
- Provides SSE-to-`StreamChunk` decoding for streaming when applicable

### Required knowledge and setup

You should know:

- Provider's API paths, request/response JSON, auth, and streaming protocol
- Req basics (request/response steps) and Finch for streaming
- ReqLLM canonical types (see [Data Structures](data-structures.md)) and normalization principles ([Core Concepts](core-concepts.md))

### Before coding

- Confirm provider supports needed capabilities (chat, tools, images, streaming)
- Gather API key/env var name and any extra headers or versions
- Start with the OpenAI-compatible defaults if at all possible

## Provider Module Structure

### File location

Create `lib/req_llm/providers/<provider>.ex`

### Using the DSL

Use the DSL to register:

- `id` (atom) - Provider identifier
- `base_url` - Default API endpoint
- `metadata` - Path to metadata file (`priv/models_dev/<provider>.json`)
- `default_env_key` - Fallback environment variable for API key
- `provider_schema` - Provider-only options

### Implementing the behavior

Required vs optional callbacks:

**Required for non-streaming:**
- `prepare_request/4` - Configure operation-specific requests
- `attach/3` - Set up authentication and Req pipeline steps
- `encode_body/1` - Transform context to provider JSON
- `decode_response/1` - Parse API responses

**Streaming (recommended):**
- `attach_stream/4` - Build complete Finch streaming request
- `decode_stream_event/2` or `/3` - Decode provider SSE events to StreamChunk structs

**Optional:**
- `extract_usage/2` - Extract usage/cost data
- `translate_options/3` - Provider-specific parameter translation
- `normalize_model_id/1` - Handle model ID aliases
- `parse_stream_protocol/2` - Custom streaming protocol handling
- `init_stream_state/1` - Initialize stateful streaming
- `flush_stream_state/2` - Flush accumulated stream state

**Response Assembly (Optional):**
- `ResponseBuilder.build_response/3` - Custom response assembly from StreamChunks

### Using Defaults

Prefer `use ReqLLM.Provider.Defaults` to get robust OpenAI-style defaults and override only when needed.

### Registering Custom Providers

If you are developing a provider outside of the `req_llm` library (e.g., in your own application), you must register it as a custom provider in your application configuration so `req_llm` can discover it.

Add the module to your `config.exs`:
```elixir
# In config/config.exs
config :req_llm, :custom_providers, [ReqLLM.Providers.Acme]
```
This tells `req_llm` to load `ReqLLM.Providers.Acme` as a valid provider module alongside its built-in providers.

## Core Implementation

### Minimal OpenAI-compatible provider

This example shows a provider that reuses defaults and only adds custom headers:

```elixir
defmodule ReqLLM.Providers.Acme do
  @moduledoc "Acme – OpenAI-compatible chat API."

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :acme,
    base_url: "https://api.acme.ai/v1",
    metadata: "priv/models_dev/acme.json",
    default_env_key: "ACME_API_KEY",
    provider_schema: [
      organization: [type: :string, doc: "Tenant/Org header"]
    ]

  use ReqLLM.Provider.Defaults

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    request = super(request, model_input, user_opts)
    org = user_opts[:organization]
    
    case org do
      nil -> request
      _ -> Req.Request.put_header(request, "x-acme-organization", org)
    end
  end
end
```

**What you get for free:**
- Non-streaming: Req pipeline with Bearer auth, JSON encode/decode in OpenAI shape
- Streaming: Finch request builder with OpenAI-compatible body and SSE decoding
- Usage extraction from response body
- Error handling and retry logic

### Non-OpenAI wire-format provider

This example shows custom encoding/decoding for a provider with different JSON schema:

```elixir
defmodule ReqLLM.Providers.Zephyr do
  @moduledoc "Zephyr – custom JSON schema, SSE streaming."

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :zephyr,
    base_url: "https://api.zephyr.ai",
    metadata: "priv/models_dev/zephyr.json",
    default_env_key: "ZEPHYR_API_KEY",
    provider_schema: [
      version: [type: :string, default: "2024-10-01"],
      tenant: [type: :string]
    ]

  use ReqLLM.Provider.Defaults

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    request = ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model_input, user_opts)
    
    request
    |> Req.Request.put_header("x-zephyr-version", user_opts[:version] || "2024-10-01")
    |> then(fn req ->
      case user_opts[:tenant] do
        nil -> req
        t -> Req.Request.put_header(req, "x-zephyr-tenant", t)
      end
    end)
  end

  @impl ReqLLM.Provider
  def encode_body(%Req.Request{} = request) do
    context = request.options[:context]
    model = request.options[:model]
    stream = request.options[:stream] == true
    tools = request.options[:tools] || []
    provider_opts = request.options[:provider_options] || []

    messages =
      Enum.map(context.messages, fn m ->
        %{
          role: Atom.to_string(m.role),
          parts: Enum.map(m.content, &encode_part/1)
        }
      end)

    body =
      %{
        model: model,
        messages: messages,
        stream: stream
      }
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:max_output_tokens, request.options[:max_tokens])
      |> maybe_put(:tools, encode_tools(tools))
      |> Map.merge(Map.new(provider_opts))

    encoded = Jason.encode!(body)
    
    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Map.put(:body, encoded)
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)
        
        with {:ok, response} <- decode_chat_response(body, req) do
          {req, %{resp | body: response}}
        else
          {:error, reason} -> 
            {req, ReqLLM.Error.Parse.exception(reason: inspect(reason))}
        end

      status ->
        {req,
         ReqLLM.Error.API.Response.exception(
           reason: "Zephyr API error",
           status: status,
           response_body: resp.body
         )}
    end
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    api_key = ReqLLM.Keys.get!(model, opts)
    url = Keyword.get(opts, :base_url, default_base_url()) <> "/chat:stream"
    
    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
    
    req = %Req.Request{
      options: %{
        model: model.model,
        context: context,
        stream: true,
        provider_options: opts[:provider_options] || []
      }
    }
    
    body = encode_body(req).body
    {:ok, Finch.build(:post, url, headers, body)}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(%{data: data}, model) do
    case Jason.decode(data) do
      {:ok, %{"type" => "delta", "text" => text}} when is_binary(text) and text != "" ->
        [ReqLLM.StreamChunk.text(text)]
        
      {:ok, %{"type" => "reasoning", "text" => think}} when is_binary(think) and think != "" ->
        [ReqLLM.StreamChunk.thinking(think)]
        
      {:ok, %{"type" => "tool_call", "name" => name, "arguments" => args}} ->
        [ReqLLM.StreamChunk.tool_call(name, Map.new(args))]
        
      {:ok, %{"type" => "usage", "usage" => usage}} ->
        [ReqLLM.StreamChunk.meta(%{usage: normalize_usage(usage), model: model.model})]
        
      {:ok, %{"type" => "done", "finish_reason" => reason}} ->
        [ReqLLM.StreamChunk.meta(%{
          finish_reason: normalize_finish_reason(reason),
          terminal?: true
        })]
        
      _ ->
        []
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => u} -> {:ok, normalize_usage(u)}
      _ -> {:error, :no_usage}
    end
  end

  @impl ReqLLM.Provider
  def translate_options(:chat, _model, opts) do
    {opts
     |> Keyword.rename(:max_tokens, :max_output_tokens)
     |> Keyword.drop([:presence_penalty]),
     []}
  end

  # Helper functions

  defp encode_part(%ReqLLM.Message.ContentPart{type: :text, text: t}), 
    do: %{"type" => "text", "text" => t}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :image_url, url: url}), 
    do: %{"type" => "image_url", "url" => url}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :image, data: bin, media_type: mt}), 
    do: %{"type" => "image", "data" => Base.encode64(bin), "media_type" => mt}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :file, data: bin, media_type: mt, name: name}), 
    do: %{"type" => "file", "name" => name, "data" => Base.encode64(bin), "media_type" => mt}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :thinking, text: t}), 
    do: %{"type" => "thinking", "text" => t}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :tool_call, name: n, arguments: a}), 
    do: %{"type" => "tool_call", "name" => n, "arguments" => a}
    
  defp encode_part(%ReqLLM.Message.ContentPart{type: :tool_result, name: n, arguments: a}), 
    do: %{"type" => "tool_result", "name" => n, "result" => a}

  defp decode_chat_response(body, req) do
    with %{"message" => %{"role" => role, "content" => content}} <- body,
         {:ok, message} <- to_message(role, content) do
      {:ok,
       %ReqLLM.Response{
         id: body["id"] || "zephyr_" <> Integer.to_string(System.unique_integer([:positive])),
         model: req.options[:model],
         context: req.options[:context] || ReqLLM.Context.new([]),
         message: message,
         usage: normalize_usage(body["usage"] || %{}),
         stream?: false
       }}
    else
      _ -> {:error, :unexpected_body}
    end
  end

  defp to_message(role, parts) do
    content_parts =
      Enum.flat_map(parts, fn
        %{"type" => "text", "text" => t} -> 
          [%ReqLLM.Message.ContentPart{type: :text, text: t}]
          
        %{"type" => "thinking", "text" => t} -> 
          [%ReqLLM.Message.ContentPart{type: :thinking, text: t}]
          
        %{"type" => "tool_call", "name" => n, "arguments" => a} -> 
          [%ReqLLM.Message.ContentPart{type: :tool_call, name: n, arguments: Map.new(a)}]
          
        %{"type" => "tool_result", "name" => n, "result" => r} -> 
          [%ReqLLM.Message.ContentPart{type: :tool_result, name: n, arguments: Map.new(r)}]
          
        _ -> []
      end)

    {:ok, %ReqLLM.Message{role: String.to_existing_atom(role), content: content_parts}}
  end

  defp encode_tools([]), do: nil
  defp encode_tools(tools) do
    Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai))
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp ensure_parsed_body(body) when is_binary(body), do: Jason.decode!(body)
  defp ensure_parsed_body(body), do: body

  defp normalize_usage(%{"prompt" => i, "completion" => o}), 
    do: %{input_tokens: i, output_tokens: o, total_tokens: (i || 0) + (o || 0)}
    
  defp normalize_usage(%{"input_tokens" => i, "output_tokens" => o, "total_tokens" => t}), 
    do: %{input_tokens: i || 0, output_tokens: o || 0, total_tokens: t || (i || 0) + (o || 0)}
    
  defp normalize_usage(_), 
    do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("tool"), do: :tool_calls
  defp normalize_finish_reason(_), do: :error
end
```

## Working with Canonical Data Structures

### Input: Context to Provider JSON

Always convert `ReqLLM.Context` (list of Messages with ContentParts) to provider JSON.

**Message structure:**
- `role` is `:system` | `:user` | `:assistant` | `:tool`
- `content` is a list of `ContentPart`

**ContentPart variants to handle:**
- `text("...")` - Plain text content
- `image_url("...")` - Image from URL
- `image(binary, mime)` - Base64-encoded image
- `file(binary, name, mime)` - File attachment
- `thinking("...")` - Reasoning tokens (for models that expose them)
- `tool_call(name, map)` - Function call request
- `tool_result(tool_call_id_or_name, map)` - Function call result

### Output: Provider JSON to Response

**Non-streaming:**

Decode provider JSON into a single assistant `ReqLLM.Message` with canonical ContentParts and fill `ReqLLM.Response`:

- `Response.message` is the assistant message
- `Response.usage` is normalized when available
- For object generation, preserve `tool_call`/`tool_result` or JSON content so `ReqLLM.Response.object/1` works consistently

**Streaming (SSE):**

Map each provider event into one or more `ReqLLM.StreamChunk`:

- `:content` — Text tokens
- `:thinking` — Reasoning tokens
- `:tool_call` — Function name + arguments (may arrive in fragments)
- `:meta` — Usage deltas, finish_reason, `terminal?: true` on completion

### Normalization principle

**One conversation model, one streaming shape, one response shape:** Never leak provider specifics to callers; normalize at the adapter boundary.

## Model Metadata Integration

### Add local patch

Create `priv/models_local/<provider>.json` to seed/supplement models before syncing:

```json
{
  "provider": { 
    "id": "acme", 
    "name": "Acme AI" 
  },
  "models": [
    {
      "id": "acme-chat-mini",
      "name": "Acme Chat Mini",
      "type": "chat",
      "capabilities": { 
        "stream": true, 
        "tool_call": true, 
        "vision": true 
      },
      "modalities": { 
        "input": ["text","image"], 
        "output": ["text"] 
      },
      "cost": { 
        "input": 0.00015, 
        "output": 0.0006 
      }
    }
  ]
}
```

### Sync registry

Run:

```bash
mix req_llm.model_sync
```

This generates `priv/models_dev/acme.json` and updates `ValidProviders`.

### Benefits

The registry enables:

- Validation with `mix mc`
- Model lookup by `"acme:acme-chat-mini"`
- Capability gating in tests

## Testing Strategy

ReqLLM uses a three-tier testing architecture:

### 1. Core package tests (no API calls)

Under `test/req_llm/` for core types/helpers.

### 2. Provider-specific tests (no API calls)

Under `test/providers/`, unit-testing your encoding/decoding and options behavior with small bodies.

**Example:**

```elixir
defmodule Providers.AcmeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart

  test "encode_body: text + tools into OpenAI shape" do
    ctx = ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.text("Hello")])])
    {:ok, model} = ReqLLM.Model.from("acme:acme-chat-mini")
    
    req =
      Req.new(url: "/chat/completions", method: :post, base_url: "https://example.test")
      |> ReqLLM.Providers.Acme.attach(model, context: ctx, stream: false, temperature: 0.0)
      |> ReqLLM.Providers.Acme.encode_body()

    assert is_binary(req.body)
    body = Jason.decode!(req.body)
    assert body["model"] =~ "acme-chat-mini"
    assert body["messages"] |> is_list()
  end
end
```

### 3. Live API coverage tests

Under `test/coverage/` using the fixture system for integration against the high-level API.

**Example:**

```elixir
defmodule Coverage.AcmeChatTest do
  use ExUnit.Case, async: false
  use ReqLLM.Test.LiveFixture, provider: :acme

  test "basic text generation" do
    {:ok, response} =
      use_fixture(:provider, "acme-basic", fn ->
        ReqLLM.generate_text("acme:acme-chat-mini", "Say hi", temperature: 0)
      end)

    assert ReqLLM.Response.text(response) =~ "hi"
  end

  test "streaming tokens" do
    {:ok, sr} =
      use_fixture(:provider, "acme-stream", fn ->
        ReqLLM.stream_text("acme:acme-chat-mini", "Count 1..3", temperature: 0)
      end)

    tokens = ReqLLM.StreamResponse.tokens(sr) |> Enum.take(3)
    assert length(tokens) >= 3
  end
end
```

### Recording fixtures

```bash
# Record fixtures during live test runs
LIVE=true mix test --only provider:acme

# Or use model compatibility tool
mix mc "acme:*" --record
```

### Validate coverage

```bash
# Quick validation
mix mc

# Sample models during development
mix mc --sample
```

## Authentication

### Use ReqLLM.Keys

Always use `ReqLLM.Keys` for key retrieval. Never read `System.get_env/1` directly.

```elixir
api_key = ReqLLM.Keys.get!(model, opts)
```

### Configuration

The DSL's `default_env_key` is the fallback env var name. `ReqLLM.Keys` also supports:

- Application config
- Per-call override via `opts[:api_key]`

### Adding authentication

Attach Bearer header in `attach/3` or use Defaults (already sets authorization):

```elixir
@impl ReqLLM.Provider
def attach(request, model_input, user_opts) do
  api_key = ReqLLM.Keys.get!(model_input, user_opts)
  
  request
  |> Req.Request.put_header("authorization", "Bearer #{api_key}")
  |> Req.Request.put_header("content-type", "application/json")
end
```

## Error Handling

### Use Splode error types

- `ReqLLM.Error.Auth` - Missing/invalid API keys
- `ReqLLM.Error.API.Request` - HTTP request issues
- `ReqLLM.Error.API.Response` - HTTP response errors
- `ReqLLM.Error.Parse` - JSON/body shape issues

### Example

In `decode_response/1`, return `{req, exception}` for non-200 or malformed payloads:

```elixir
@impl ReqLLM.Provider
def decode_response({req, resp}) do
  case resp.status do
    200 ->
      body = ensure_parsed_body(resp.body)
      
      with {:ok, response} <- decode_chat_response(body, req) do
        {req, %{resp | body: response}}
      else
        {:error, reason} -> 
          {req, ReqLLM.Error.Parse.exception(reason: inspect(reason))}
      end

    status ->
      {req,
       ReqLLM.Error.API.Response.exception(
         reason: "API error",
         status: status,
         response_body: resp.body
       )}
  end
end
```

The pipeline will propagate errors consistently to callers.

## Response Assembly with ResponseBuilder

### Why ResponseBuilder Exists

Different LLM providers have subtle differences in how they represent responses, tool calls, finish reasons, and metadata. Previously, these differences were handled in multiple places (streaming vs non-streaming, provider-specific decoders), leading to behavioral inconsistencies.

The `ResponseBuilder` behaviour centralizes provider-specific Response assembly logic, ensuring that:

1. **Streaming and non-streaming produce identical Response structs**
2. **Provider quirks are handled in one place per provider**
3. **New providers have a clear extension point**

### How It Works

Both streaming and non-streaming paths converge on `ResponseBuilder`:

1. Decode wire format to `[StreamChunk.t()]`
2. Collect metadata (usage, finish_reason, provider-specific)
3. Call the appropriate builder:

```elixir
builder = ResponseBuilder.for_model(model)
{:ok, response} = builder.build_response(chunks, metadata, opts)
```

### Routing Logic

`ResponseBuilder.for_model/1` routes to provider-specific builders:

- Anthropic models → `Anthropic.ResponseBuilder`
- Google/Vertex models → `Google.ResponseBuilder`
- OpenAI Responses API models → `OpenAI.ResponsesAPI.ResponseBuilder`
- All others → `Provider.Defaults.ResponseBuilder`

### When to Implement a Custom ResponseBuilder

Most providers can use `Provider.Defaults.ResponseBuilder`. Implement a custom builder when:

- **Content block requirements**: Anthropic requires content blocks to never be empty
- **Provider-specific metadata**: OpenAI Responses API needs to propagate `response_id` for stateless multi-turn
- **Finish reason detection**: Google needs to detect `functionCall` to set correct finish_reason
- **Custom tool call handling**: Provider has non-standard tool call representation

### Example: Custom ResponseBuilder

```elixir
defmodule ReqLLM.Providers.Zephyr.ResponseBuilder do
  @moduledoc "Custom ResponseBuilder for Zephyr provider."

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder

  @impl true
  def build_response(chunks, metadata, opts) do
    # Delegate to default builder for standard processing
    with {:ok, response} <- DefaultBuilder.build_response(chunks, metadata, opts) do
      # Apply provider-specific post-processing
      response = apply_zephyr_quirks(response, metadata)
      {:ok, response}
    end
  end

  defp apply_zephyr_quirks(response, metadata) do
    # Example: Zephyr includes session_id in metadata
    case metadata[:session_id] do
      nil -> response
      sid -> %{response | provider_meta: Map.put(response.provider_meta, :session_id, sid)}
    end
  end
end
```

Then register the builder by adding a clause to `ResponseBuilder.for_model/1` (for built-in providers) or by pattern matching on your model in your provider's streaming/non-streaming paths.

## Step-by-Step Example

Let's add a fictional provider called "Acme" from start to finish.

### 1. Create provider module

File: `lib/req_llm/providers/acme.ex`

```elixir
defmodule ReqLLM.Providers.Acme do
  @moduledoc "Acme – OpenAI-compatible chat API."

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :acme,
    base_url: "https://api.acme.ai/v1",
    metadata: "priv/models_dev/acme.json",
    default_env_key: "ACME_API_KEY",
    provider_schema: [
      organization: [type: :string, doc: "Tenant/Org header"]
    ]

  use ReqLLM.Provider.Defaults

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    request = super(request, model_input, user_opts)
    org = user_opts[:organization]
    
    case org do
      nil -> request
      _ -> Req.Request.put_header(request, "x-acme-organization", org)
    end
  end
end
```

### 2. Add model metadata

File: `priv/models_local/acme.json`

```json
{
  "provider": { 
    "id": "acme", 
    "name": "Acme AI" 
  },
  "models": [
    {
      "id": "acme-chat-mini",
      "name": "Acme Chat Mini",
      "type": "chat",
      "capabilities": { 
        "stream": true, 
        "tool_call": true, 
        "vision": true 
      },
      "modalities": { 
        "input": ["text","image"], 
        "output": ["text"] 
      },
      "cost": { 
        "input": 0.00015, 
        "output": 0.0006 
      }
    }
  ]
}
```

### 3. Sync registry

```bash
mix req_llm.model_sync
```

### 4. Quick smoke test

```bash
export ACME_API_KEY=sk-...
mix req_llm.gen "Hello" --model acme:acme-chat-mini
```

### 5. Provider unit tests

File: `test/providers/acme_test.exs`

```elixir
defmodule Providers.AcmeTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart

  test "encode_body: text + tools into OpenAI shape" do
    ctx = ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.text("Hello")])])
    {:ok, model} = ReqLLM.Model.from("acme:acme-chat-mini")
    
    req =
      Req.new(url: "/chat/completions", method: :post, base_url: "https://example.test")
      |> ReqLLM.Providers.Acme.attach(model, context: ctx, stream: false, temperature: 0.0)
      |> ReqLLM.Providers.Acme.encode_body()

    assert is_binary(req.body)
    body = Jason.decode!(req.body)
    assert body["model"] =~ "acme-chat-mini"
    assert body["messages"] |> is_list()
  end
end
```

### 6. Coverage tests with fixtures

File: `test/coverage/acme_chat_test.exs`

```elixir
defmodule Coverage.AcmeChatTest do
  use ExUnit.Case, async: false
  use ReqLLM.Test.LiveFixture, provider: :acme

  test "basic text generation" do
    {:ok, response} =
      use_fixture(:provider, "acme-basic", fn ->
        ReqLLM.generate_text("acme:acme-chat-mini", "Say hi", temperature: 0)
      end)

    assert ReqLLM.Response.text(response) =~ "hi"
  end

  test "streaming tokens" do
    {:ok, sr} =
      use_fixture(:provider, "acme-stream", fn ->
        ReqLLM.stream_text("acme:acme-chat-mini", "Count 1..3", temperature: 0)
      end)

    tokens = ReqLLM.StreamResponse.tokens(sr) |> Enum.take(3)
    assert length(tokens) >= 3
  end
end
```

### 7. Record fixtures

```bash
# Option 1: During test run
LIVE=true mix test --only provider:acme

# Option 2: Using model compat tool
mix mc "acme:*" --record
```

### 8. Validate models

```bash
# Validate Acme models
mix req_llm.model_compat acme

# List all registered providers/models
mix mc --available
```

## Best Practices

### Simplicity-first and normalization

- Prefer using `ReqLLM.Provider.Defaults`. Only override what the provider truly deviates on
- Keep `prepare_request/4` a thin dispatcher; centralize option prep in `attach/3` and the defaults pipeline

### Code style (from AGENTS.md)

- No comments inside function bodies. Use clear naming and module docs
- Prefer pattern matching to conditionals
- Use `{:ok, result}` | `{:error, reason}` tuples for fallible helpers

### Options translation

- Use `translate_options/3` to rename/drop provider-specific params (e.g., `max_tokens` → `max_output_tokens`)

### Tools and multimodal

- Always map tools via `ReqLLM.Tool.to_schema/2`
- Respect `ContentPart` variants for images/files. Base64 encode if the provider requires it

### Streaming

- Build the Finch request in `attach_stream/4`
- Decode events to `StreamChunk` in `decode_stream_event/2` or `/3`
- Emit terminal meta chunk with `finish_reason` and usage if provided

### Testing incrementally

- Start with non-streaming happy path, then add streaming and tools
- Record minimal, deterministic fixtures (`temperature: 0`)

## Advanced Topics

### When to consider the advanced path

- Provider uses non-SSE streaming (binary protocol) or chunked JSON requiring stateful accumulation
- Models with unique parameter semantics that demand `translate_options/3` and capability gating
- Complex multimodal tool invocation requiring custom mapping of multi-part tool args/results

### Advanced implementations

- Implement `parse_stream_protocol/2` for custom binary protocols (e.g., AWS Event Stream)
- Implement `init_stream_state/1`, `decode_stream_event/3`, `flush_stream_state/2` to accumulate partial tool_call args or demultiplex multi-channel events
- Implement `normalize_model_id/1` for regional aliases and `translate_options/3` with warning aggregation
- Provide provider-specific usage accounting that merges multi-phase usage deltas

## Callback Reference

### What to implement and when

**prepare_request/4**
- Build Req for the operation
- Defaults cover `:chat`, `:object`, `:embedding`

**attach/3**
- Set headers, auth, and pipeline steps
- Defaults add Bearer, retry, error, usage, fixture steps

**encode_body/1**
- Transform options/context to provider JSON
- Defaults are OpenAI-compatible; override for custom wire formats

**decode_response/1**
- Map provider body to Response or error
- Defaults map OpenAI-style bodies; override if your shape differs

**attach_stream/4**
- Must return `{:ok, Finch.Request.t()}`
- Defaults build OpenAI-compatible streaming requests; override for custom endpoints/headers

**decode_stream_event/2 or /3**
- Map provider events to StreamChunk
- Defaults handle OpenAI-compatible deltas

**extract_usage/2**
- Normalize usage tokens/cost if provider deviates from standard usage shape

**translate_options/3**
- Rename/drop options per model or operation

**ResponseBuilder.build_response/3**
- Build final Response struct from accumulated StreamChunks and metadata
- Defaults handle OpenAI-compatible responses; override for provider-specific quirks
- Required parameters: `chunks` (list of StreamChunk), `metadata` (map with usage, finish_reason, etc.), `opts` (keyword list with `:context` and `:model`)

## Summary

Adding a provider to ReqLLM involves:

1. Creating a provider module with the DSL and behavior implementation
2. Implementing encoding/decoding for the provider's wire format
3. Optionally implementing a custom `ResponseBuilder` for provider-specific response assembly
4. Adding model metadata and syncing the registry
5. Writing tests at all three tiers (core, provider, coverage)
6. Recording fixtures for validation

By following these guidelines and leveraging the defaults, you can add robust, well-tested provider support that maintains ReqLLM's normalization principles across all AI interactions.
