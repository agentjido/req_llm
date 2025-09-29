# ReqLLM Examples

This directory contains examples demonstrating ReqLLM capabilities.

## Quick Start

Run the demo to see the agent in action:

```bash
mix run lib/examples/demo.exs
```

## Files

- **`agent.ex`** - A GenServer-based AI agent with streaming and tool calling
- **`demo.exs`** - Interactive demonstration of agent capabilities

## Features Demonstrated

- **Streaming Text Generation** - Real-time output using Claude 3.5
- **Tool Calling** - Calculator and web search with proper argument parsing  
- **Conversation History** - Maintains context across interactions
- **Two-Step Completion** - Handles tool execution then final response

## Agent Usage

```elixir
# Start the agent
{:ok, agent} = ReqLLM.Examples.Agent.start_link()

# Send prompts
ReqLLM.Examples.Agent.prompt(agent, "What's 15 * 7?")
#=> Streams: "I'll calculate that for you..."
#=> [Tool: calculator] 105  
#=> Streams: "15 * 7 = 105"
#=> {:ok, "15 * 7 = 105"}

# Agent remembers conversation history
ReqLLM.Examples.Agent.prompt(agent, "What was that result again?")
#=> {:ok, "The result of 15 * 7 was 105."}
```

## Available Tools

- **Calculator** - Evaluates mathematical expressions
