# ReqLLM Agent Tutorial

Let's make an agent!

This tutorial walks through building a tool-using agent in Elixir with ReqLLM. We start with a simple streaming agent and build up to a full tool-execution loop.

## Agent Workflow

The agent (`step2_tool_calling.exs`) implements a 3-step "Reason-Act-Answer" loop:

1. **Initial Request (Reason)**
   - The user asks a question (e.g., "What is 842 * 73?").
   - We send the question + available tools (Calculator) to the LLM.
   - The LLM decides it needs a tool and returns a `tool_calls` response instead of text.

2. **Execute Tools (Act)**
   - The agent parses the tool call (e.g., `calculator(expression="842 * 73")`).
   - It executes the tool locally (using `Abacus.eval/1`).
   - The result ("61466") is formatted as a tool result message.

3. **Final Answer (Answer)**
   - We send the tool result back to the LLM.
   - The LLM sees the result and generates the final natural language answer.
   - The response is streamed back to the user.

## Key Concepts

- **Zero Magic**: We manually handle context, parsing, and execution to show exactly how it works.
- **Streaming**: We demonstrate how to stream both tool definitions (in debug mode) and final answers.
- **State Management**: A GenServer holds the conversation history (`ReqLLM.Context`).
- **Tool Definition**: Tools are defined using `ReqLLM.Tool.new/1` with JSON Schema parameters.
