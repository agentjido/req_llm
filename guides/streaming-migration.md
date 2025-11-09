# Streaming Migration Guide

This guide helps you migrate from the deprecated `stream_text!/3` pattern to the new `StreamResponse` API introduced in ReqLLM's Finch-based streaming refactor.

## Overview

ReqLLM's streaming implementation has been completely redesigned to use Finch directly instead of REQ, providing:

- **HTTP/2 multiplexing** for concurrent streams
- **Asynchronous metadata collection** (usage, finish_reason)
- **Production-grade connection pooling**
- **Better error handling and resource cleanup**
- **Unified API across all providers**

## Migration Patterns

### Basic Streaming

**Before** (deprecated):

```elixir
ReqLLM.stream_text!(model, "Tell me a story")
|> Stream.each(&IO.write/1)
|> Stream.run()
```

**After** (recommended):

```elixir
{:ok, response} = ReqLLM.stream_text(model, "Tell me a story")
response
|> ReqLLM.StreamResponse.tokens()
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### Error Handling

**Before** (raised exceptions):

```elixir
try do
  ReqLLM.stream_text!(model, messages)
  |> Stream.each(&IO.write/1)
  |> Stream.run()
rescue
  error -> handle_error(error)
end
```

**After** (proper error tuples):

```elixir
case ReqLLM.stream_text(model, messages) do
  {:ok, response} ->
    response
    |> ReqLLM.StreamResponse.tokens()
    |> Stream.each(&IO.write/1)
    |> Stream.run()

  {:error, reason} ->
    handle_error(reason)
end
```

### Getting Usage Metadata

**Before** (not available during streaming):

```elixir
# Usage was only available after completion via separate call
ReqLLM.stream_text!(model, messages) |> Stream.run()
# No way to get usage metadata for the stream
```

**After** (concurrent metadata collection):

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages)

# Stream tokens in real-time
tokens_task = Task.start(fn ->
  response
  |> ReqLLM.StreamResponse.tokens()
  |> Stream.each(&IO.write/1)
  |> Stream.run()
end)

# Collect metadata concurrently
usage = ReqLLM.StreamResponse.usage(response)
finish_reason = ReqLLM.StreamResponse.finish_reason(response)

IO.puts("\\nUsage: #{inspect(usage)}")
IO.puts("Finish reason: #{finish_reason}")
```

### Simplified Text Collection

**Before** (manual accumulation):

```elixir
text =
  ReqLLM.stream_text!(model, messages)
  |> Enum.join("")
```

**After** (built-in helper):

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages)
text = ReqLLM.StreamResponse.text(response)
```

### LiveView Integration

**Before**:

```elixir
def handle_info({:stream_text, model, messages}, socket) do
  # No good way to handle this with the old API
  {:noreply, socket}
end
```

**After**:

```elixir
def handle_info({:stream_text, model, messages}, socket) do
  case ReqLLM.stream_text(model, messages) do
    {:ok, response} ->
      # Stream tokens to the client
      Task.start(fn ->
        response
        |> ReqLLM.StreamResponse.tokens()
        |> Stream.each(&send(self(), {:token, &1}))
        |> Stream.run()
      end)

      # Handle metadata when available
      Task.start(fn ->
        usage = ReqLLM.StreamResponse.usage(response)
        send(self(), {:usage, usage})
      end)

      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Stream failed: #{inspect(reason)}")}
  end
end

def handle_info({:token, token}, socket) do
  {:noreply, push_event(socket, "token", %{text: token})}
end

def handle_info({:usage, usage}, socket) do
  {:noreply, push_event(socket, "usage", usage)}
end
```

## Backward Compatibility

If you need to migrate gradually, you can convert `StreamResponse` to the legacy `Response` format:

```elixir
{:ok, stream_response} = ReqLLM.stream_text(model, messages)
{:ok, legacy_response} = ReqLLM.StreamResponse.to_response(stream_response)

# Now compatible with existing Response-based code
text = ReqLLM.Response.text(legacy_response)
usage = ReqLLM.Response.usage(legacy_response)
```

**Note**: This conversion negates the streaming benefits since it materializes the entire stream.

## New Features

### Cancellation Support

```elixir
{:ok, response} = ReqLLM.stream_text(model, "Very long story...")

# Start streaming
task = Task.async(fn ->
  response
  |> ReqLLM.StreamResponse.tokens()
  |> Stream.take(10)  # Only take first 10 tokens
  |> Enum.to_list()
end)

tokens = Task.await(task)

# Cancel remaining work to free resources
response.cancel.()
```

### Resource Management

The new system automatically manages resources:

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages)

# Resources are cleaned up automatically when stream completes
response
|> ReqLLM.StreamResponse.tokens()
|> Stream.run()

# Or manually if needed
response.cancel.()
```

### Connection Pool Configuration

The new Finch-based system allows connection pool configuration:

```elixir
# In config.exs
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http2, :http1], size: 1, count: 16]
    }
  ]

# Use custom Finch instance per request
{:ok, response} = ReqLLM.stream_text(model, messages, finch_name: MyApp.Finch)
```

## Common Migration Issues

### Issue: Stream chunks have different structure

**Problem**: The old API returned chunks with `.text` field, new API returns raw text tokens.

**Solution**: Use `ReqLLM.StreamResponse.tokens()` to get text-only stream:

```elixir
# Old: chunk.text
# New: direct text tokens
response
|> ReqLLM.StreamResponse.tokens()
|> Stream.each(&IO.write/1)  # &1 is already text
```

### Issue: No access to raw StreamChunk structs

**Problem**: Sometimes you need the full chunk structure, not just text.

**Solution**: Access the raw stream directly:

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages)

# Raw StreamChunk structs
response.stream
|> Stream.each(fn chunk ->
  case chunk.type do
    :content -> IO.write(chunk.text)
    :tool_call -> handle_tool_call(chunk)
    _ -> :ignore
  end
end)
|> Stream.run()
```

### Shared metadata access

Streaming responses now expose a reusable metadata handle. The handle collects metadata once,
caches the result, and lets every caller await it independently—no more racing or blocking on a
single task:

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages)

# Multiple consumers can await the same metadata handle safely
metadata_handle = response.metadata_handle

Task.start(fn ->
  usage = ReqLLM.StreamResponse.MetadataHandle.await(metadata_handle)
  log_usage(usage)
end)

Task.start(fn ->
  metadata = ReqLLM.StreamResponse.MetadataHandle.await(metadata_handle)
  update_billing(metadata.usage)
end)
```

## Testing Migration

Update your tests to expect the new return format:

**Before**:

```elixir
test "streams text" do
  chunks = ReqLLM.stream_text!("anthropic:claude-3-sonnet", "Hello") |> Enum.take(5)
  assert Enum.all?(chunks, &is_binary/1)
end
```

**After**:

```elixir
test "streams text" do
  {:ok, response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello")
  tokens = response |> ReqLLM.StreamResponse.tokens() |> Enum.take(5)
  assert Enum.all?(tokens, &is_binary/1)
end
```

## Performance Considerations

The new streaming system provides significant performance improvements:

1. **HTTP/2 Multiplexing**: Multiple concurrent streams over single connection
2. **Reduced Memory Usage**: Lazy stream evaluation prevents buffering
3. **Concurrent Processing**: Metadata collection doesn't block token streaming
4. **Connection Reuse**: Finch pools reduce connection overhead

For high-throughput applications, consider tuning the connection pool:

```elixir
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http2], size: 1, count: 32]
    }
  ]
```

## Next Steps

1. Update your code to use `stream_text/3` instead of `stream_text!/3`
2. Replace manual error handling with proper `{:ok, response}` pattern matching
3. Use `StreamResponse` helper functions for common operations
4. Configure connection pools for your deployment scale
5. Test the migration thoroughly with your specific use cases

The deprecated `stream_text!/3` function will be removed in a future major version. Please migrate at your earliest convenience.
