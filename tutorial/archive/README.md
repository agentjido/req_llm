# SimpleAgent Tutorial

This tutorial demonstrates building AI agents with ReqLLM in progressive steps, from basic streaming to production-ready patterns.

## Files

- **simple_agent_parser.ex** - Shared helper module for parsing streaming chunks
- **simple_agent_tutorial.livemd** - Interactive LiveBook tutorial (V1 & V2)
- **v1_streaming_agent.exs** - Basic streaming agent
- **v2_tool_calling_agent.exs** - Synchronous tool calling
- **v3_async_tool_calling_agent.exs** - Phased processing with `{:continue, action}`
- **v4_phoenix_liveview_agent.exs** - Phoenix LiveView streaming UI
- **v5_parallel_tools_agent.exs** - Parallel tool execution with Task.Supervisor

## Prerequisites

Set your Anthropic API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

## Running the Scripts

### V1: Basic Streaming Agent

```bash
elixir v1_streaming_agent.exs
```

This demonstrates:
- Real-time streaming of LLM responses to console
- Simple GenServer-based agent architecture
- Conversation history management

### V2: Synchronous Tool-Calling Agent

```bash
elixir v2_tool_calling_agent.exs
```

This demonstrates:
- Tool definition with ReqLLM.Tool
- Safe math expression evaluation using Abacus
- Two-step tool calling pattern:
  1. Stream to detect tool calls
  2. Execute tool and get final answer with generate_text
- **Blocking**: `handle_call` waits for entire tool execution loop

### V3: Phased Processing Agent

```bash
elixir v3_async_tool_calling_agent.exs
```

This demonstrates:
- **Non-blocking reply to caller**: Uses `{:continue, action}` pattern
- Clean separation: Stream → Execute Tools → Finalize (3 phases)
- GenServer.reply/2 pattern for deferred responses
- Note: GenServer itself remains busy during handle_continue
- Enhanced console output with step indicators

### V4: Phoenix LiveView Streaming Agent

```bash
elixir v4_phoenix_liveview_agent.exs
# Open http://localhost:4000 in your browser
```

This demonstrates:
- Single-file Phoenix LiveView application with phoenix_playground
- Real-time streaming of AI responses to the browser
- Tool calling with visual feedback in the UI
- Conversation history display
- Clean, responsive chat interface

### V5: Parallel Tool Execution Agent

```bash
elixir v5_parallel_tools_agent.exs
```

This demonstrates:
- Task.Supervisor for managing concurrent tool executions
- Per-tool timeouts with graceful error handling (5s default)
- Parallel execution of multiple tool calls
- Performance metrics showing parallel vs sequential timing
- Production-ready error handling and monitoring

## LiveBook Tutorial

Open `simple_agent_tutorial.livemd` in LiveBook for an interactive experience with both versions side-by-side.

## What You'll Build

### Version 1: Streaming Agent
A minimal GenServer that streams assistant responses in real-time, showing tokens as they arrive.

### Version 2: Synchronous Tool-Calling Agent
Enhanced agent with:
- Calculator tool using Abacus for safe math evaluation
- Tool call detection from streaming chunks
- Final answer generation after tool execution
- All-in-one synchronous flow (easy to understand)

### Version 3: Phased Processing Agent
Advanced agent with:
- `{:continue, action}` pattern for non-blocking reply to caller
- Clean separation of concerns (3 distinct phases)
- GenServer.reply/2 pattern for deferred responses
- Better error handling and observability

### Version 4: Phoenix LiveView Streaming Agent
Browser-based chat interface with:
- Single-file Phoenix application using phoenix_playground
- Real-time streaming updates in the browser
- Visual tool call feedback and conversation history
- Responsive, production-ready UI

### Version 5: Parallel Tool Execution Agent
Production-grade agent with:
- Task.Supervisor for concurrent tool execution
- Per-tool timeouts and error isolation
- Performance metrics comparing parallel vs sequential
- True concurrency for multiple tool calls

## Key Concepts

- **Streaming**: Use `ReqLLM.stream_text/3` for real-time output, `ReqLLM.StreamResponse.tokens/1` to extract text
- **Context Management**: Use `ReqLLM.Context` for conversation history with helper functions
- **Tool Calling**: Define tools with `ReqLLM.Tool` and execute with callbacks
- **Two-Step Pattern**: Stream for tool detection, then `generate_text/3` for final answer
- **Phased Processing**: Use `{:continue, action}` in GenServer for non-blocking reply to caller
- **Parallel Execution**: Use `Task.Supervisor.async_stream_nolink` for concurrent tool calls
- **Parser Helpers**: Shared `SimpleAgent.Parser` module extracts common streaming patterns

## Screen Recording Tips

The scripts are designed for easy screen recording demonstrations:

1. **V1**: Show basic streaming (fast, simple)
2. **V2**: Demonstrate synchronous tool calling (clear, easy to follow)
3. **V3**: Show phased processing pattern (non-blocking reply)
4. **V4**: Demonstrate browser-based streaming UI (visual, interactive)
5. **V5**: Show parallel tool execution with timing metrics (production-ready)

Each script has:
- Clear console output with emoji indicators
- Questions that progress from simple to complex
- Detailed step-by-step explanations in console

## Progression Path

**Beginners**: Start with V1 → V2 (synchronous, easier to understand)  
**Intermediate**: Add V3 to understand `{:continue, action}` pattern  
**Web Developers**: Try V4 for Phoenix LiveView integration  
**Production**: Use V5 as template for concurrent real-world agents
