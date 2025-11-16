# Architecture Comparison: V2 → V3 → V5

This document compares the synchronous (V2), phased processing (V3), and parallel execution (V5) agent patterns.

## Shared Flow Across V2, V3, V5

All versions that use tools follow the same 3 logical phases:

1. **Stream model output to detect tool calls** - Stream the LLM response while detecting tool calls
2. **Execute tools and append results to history** - Run tool functions and add their results to conversation history
3. **Call `generate_text/3` to produce final answer** - Generate the final response using the complete history

The versions differ only in:
- **How these phases are sequenced** - Synchronously (V2), via `{:continue}` (V3), or with parallel tasks (V5)
- **Where the output goes** - Console (V2, V3, V5) vs LiveView (V4)

### Shared Core Module

The `SimpleAgent.Core` module centralizes this 3-phase logic:

```elixir
# Phase 1: Stream and detect tools
{:ok, %{assistant_text: text, tool_calls: calls}} = 
  Core.stream_with_tools(model, history, tools)

# Phase 2: Execute tools sequentially
history = Core.execute_tools_sequential(history, tools, calls)

# Phase 3: Finalize
{:ok, final_text} = Core.finalize(model, history)
```

This allows each version to focus on *how* it schedules the phases, not on re-implementing the tool-calling mechanics.

## V2: Synchronous Pattern

### Flow
```
handle_call({:ask, text}, from, state)
  ├─> Append user message
  ├─> Stream response (blocks)
  ├─> Detect tool calls
  ├─> Execute tools (blocks)
  ├─> Generate final answer (blocks)
  └─> Reply to caller with result
```

### Pros
✅ Simple to understand and reason about  
✅ All logic in one place  
✅ Easy to debug (linear execution)  
✅ Perfect for tutorials and simple use cases

### Cons
❌ Blocks GenServer during entire operation  
❌ Caller waits for complete tool execution loop  
❌ Hard to add timeouts per phase  
❌ Can't handle parallel tool execution easily  
❌ Difficult to add retries or circuit breakers

### Code Structure
```elixir
def handle_call({:ask, text}, _from, state) do
  # Everything happens here synchronously
  history = append_user(state.history, text)
  {:ok, stream} = stream_text(...)
  tool_calls = extract_tools(stream)
  history = execute_tools(history, tool_calls)
  {:ok, final} = generate_text(...)
  {:reply, {:ok, final}, state}
end
```

## V3: Phased Processing Pattern with `{:continue, action}`

### Flow
```
handle_call({:ask, text}, from, state)
  └─> {:noreply, state, {:continue, {:stream_response, from}}}
       ↓
handle_continue({:stream_response, from}, state)
  ├─> Stream response (async)
  ├─> Detect tool calls
  └─> {:noreply, state, {:continue, {:execute_tools, from, calls}}}
       ↓
handle_continue({:execute_tools, from, calls}, state)
  ├─> Execute tools
  └─> {:noreply, state, {:continue, {:finalize_response, from}}}
       ↓
handle_continue({:finalize_response, from}, state)
  ├─> Generate final answer
  └─> Reply to caller with result
```

### Pros
✅ Non-blocking callers (server replies later via `GenServer.reply/2`)  
✅ Clean separation of concerns (3 phases)  
✅ Easy to add timeouts per phase  
✅ Can parallelize tool execution  
✅ Simple to add retries, circuit breakers  
✅ Better observability (can log each phase)  
✅ Production-ready pattern

### Cons
❌ More complex to understand initially  
❌ Code split across multiple functions  
❌ Requires understanding `{:continue, action}` pattern

### Important Note
The GenServer still executes all phases sequentially in a single process; callers are non-blocked because we defer the reply with `GenServer.reply/2`.

### Code Structure
```elixir
def handle_call({:ask, text}, from, state) do
  state = append_user(state.history, text)
  {:noreply, state, {:continue, {:stream_response, from}}}
end

def handle_continue({:stream_response, from}, state) do
  {:ok, stream} = stream_text(...)
  tool_calls = extract_tools(stream)
  {:noreply, state, {:continue, {:execute_tools, from, tool_calls}}}
end

def handle_continue({:execute_tools, from, calls}, state) do
  state = execute_tools(state, calls)
  {:noreply, state, {:continue, {:finalize_response, from}}}
end

def handle_continue({:finalize_response, from}, state) do
  {:ok, final} = generate_text(...)
  GenServer.reply(from, {:ok, final})
  {:noreply, state}
end
```

## V5: Parallel Execution Pattern with Task.Supervisor

### Flow
```
handle_call({:ask, text}, from, state)
  └─> {:noreply, state, {:continue, {:stream_response, from}}}
       ↓
handle_continue({:stream_response, from}, state)
  ├─> Stream response (async)
  ├─> Detect tool calls
  └─> {:noreply, state, {:continue, {:execute_tools_parallel, from, calls}}}
       ↓
handle_continue({:execute_tools_parallel, from, calls}, state)
  ├─> Spawn parallel tasks via Task.Supervisor.async_stream_nolink
  ├─> Each tool executes concurrently with timeout
  ├─> Collect results with error isolation
  └─> {:noreply, state, {:continue, {:finalize_response, from}}}
       ↓
handle_continue({:finalize_response, from}, state)
  ├─> Generate final answer
  └─> Reply to caller with result
```

### Pros
✅ V5 is the first version where tool execution itself runs in separate processes via `Task.Supervisor`, freeing the agent process while tools run  
✅ True parallel execution of tools  
✅ Per-tool timeouts (default: 5000ms)  
✅ Error isolation - one tool failure doesn't block others  
✅ Performance metrics and monitoring  
✅ Production-ready supervision  
✅ Scales with CPU cores (`max_concurrency: System.schedulers_online()`)  
✅ Handles tool timeouts gracefully with `:on_timeout`

### Cons
❌ Most complex pattern  
❌ Requires understanding Task.Supervisor  
❌ More moving parts to debug

### Important Note
This is the first version where the *server* process itself is freed during tool execution. V2 and V3 both execute tools in the GenServer process itself.

### Code Structure
```elixir
def handle_continue({:execute_tools_parallel, from, calls}, state) do
  results =
    Task.Supervisor.async_stream_nolink(
      state.supervisor,
      tool_calls,
      fn call -> execute_tool(call) end,
      timeout: 5_000,
      on_timeout: :kill_task,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.to_list()
  
  # Process results and continue...
end
```

## Key Architectural Differences

| Aspect | V2 (Synchronous) | V3 (Phased) | V5 (Parallel) |
|--------|------------------|-------------|---------------|
| **Blocking** | Yes - caller waits | No - returns immediately | No - returns immediately |
| **Phases** | 1 monolithic | 3 separate | 3 separate |
| **Reply** | `{:reply, result, state}` | `GenServer.reply(from, result)` | `GenServer.reply(from, result)` |
| **Tool Execution** | Sequential | Sequential | Parallel |
| **Timeout Control** | Single timeout for all | Per-phase timeouts possible | Per-tool timeouts |
| **Error Isolation** | One error stops all | Phase-level | Tool-level |
| **Concurrency** | None | None | True parallelism |
| **Performance** | Slowest | Medium | Fastest |
| **Testing** | Test whole flow | Test each phase | Test phases + tasks |
| **Production Ready** | Basic use cases | Complex workflows | High-performance systems |

## When to Use Each

### Use V2 (Synchronous) When:
- Building tutorials or demos
- Simple single-tool scenarios
- You need linear, easy-to-follow code
- Blocking is acceptable (short operations)

### Use V3 (Phased) When:
- Building production agents with phased workflows
- Need non-blocking reply to caller
- Want clear separation of concerns
- Need per-phase observability
- Sequential tool execution is acceptable

### Use V5 (Parallel) When:
- Multiple tools must run concurrently
- Performance is critical
- Tools can execute independently
- Need per-tool timeouts and error isolation
- Building high-throughput systems
- Tools have varying execution times

## Evolution Path

```
V1 (Streaming)
  ↓
V2 (Sync Tool Calling)
  ↓
V3 (Phased Processing)
  ↓
V4 (Phoenix LiveView UI)  ←─ For web interfaces
  ↓
V5 (Parallel Execution)  ←─ For high performance
  ↓
Your Production Agent
  - Add Circuit Breaker for external APIs
  - Add Telemetry for observability
  - Add Backoff for retries
  - Add persistent storage
```

## Code Metrics

| Metric | V1 | V2 | V3 | V4 | V5 |
|--------|----|----|-----|----|----|
| Lines of Code | ~75 | ~160 | ~185 | ~370 | ~260 |
| GenServer Callbacks | 2 | 2 | 4 | 0 (LiveView) | 4 |
| Additional Concepts | - | Tools | {:continue} | LiveView | Task.Supervisor |
| Complexity | Low | Medium | Medium | Medium-High | High |
| Testability | Good | Good | Excellent | Good | Excellent |
| Production Ready | Demo | Simple | Yes | Yes (UI) | Yes (Performance) |

## Summary

**V2** is perfect for learning and simple use cases. The synchronous flow makes it easy to understand what's happening.

**V3** introduces phased processing with `{:continue, action}`, providing non-blocking replies and clean separation of concerns.

**V4** demonstrates browser-based streaming with Phoenix LiveView, perfect for building interactive AI interfaces.

**V5** is the high-performance pattern. It uses Task.Supervisor for true parallel tool execution with per-tool timeouts and error isolation.

For tutorial progression:
1. Start with V1/V2 to learn core concepts
2. Add V3 to understand phased processing
3. Try V4 if building web interfaces
4. Use V5 as template for production systems requiring high performance
