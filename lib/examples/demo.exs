#!/usr/bin/env elixir

# ReqLLM Agent Demo
#
# This script demonstrates the ReqLLM.Examples.Agent capabilities:
# - Streaming text generation with Claude 3.5
# - Tool calling with proper argument parsing
# - Conversation history maintenance
#
# Run with: mix run lib/examples/demo.exs

# Clean startup and suppress debug logging
Application.ensure_all_started(:req_llm)
Logger.configure(level: :warning)

# Start the agent
{:ok, agent} = ReqLLM.Examples.Agent.start_link()

IO.puts("ReqLLM Agent Demo")
IO.puts("═══════════════════════════════════════")
IO.puts("")

# Demo 1: Basic conversation
IO.puts("Basic Conversation")
IO.puts("─────────────────────")
IO.puts("User: Hello! What can you help me with?")
IO.write("Assistant: ")
{:ok, _response} = ReqLLM.Examples.Agent.prompt(agent, "Hello! What can you help me with?")
IO.puts("")
IO.puts("")

# Demo 2: Calculator tool usage
IO.puts("Calculator Tool")
IO.puts("──────────────────")
num1 = Enum.random(1..999)
num2 = Enum.random(1..999)
num3 = Enum.random(1..999)
question = "What's #{num1} * #{num2} + #{num3}?"
IO.puts("User: #{question}")
IO.write("Assistant: ")
{:ok, _response} = ReqLLM.Examples.Agent.prompt(agent, question)
IO.puts("")
IO.puts("")

IO.puts("═══════════════════════════════════════")
IO.puts("Demo complete!")
