# Getting Started

This guide covers your first API call, basic configuration, and the core functions (`generate_text/3`, `stream_text/3`, `generate_object/4`) for quick integration across providers.

## Installation

Add ReqLLM to your dependencies:

```elixir
def deps do
  [
    {:req_llm, "~> 1.0.0"}
  ]
end
```

## Generate Text

Generate text with a single function call or stream tokens in real-time:

```elixir
# Configure your API key 
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.generate_text!("anthropic:claude-haiku-4-5", "Hello")
# Returns: "Hello! How can I assist you today?"

{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Tell me a story")
ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&IO.write/1)
|> Stream.run()
```

## Structured Data

Generate type-validated objects using NimbleOptions schemas:

```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]
{:ok, response} = ReqLLM.generate_object("anthropic:claude-haiku-4-5", "Generate a person", schema)
object = ReqLLM.Response.object(response)
# object => %{name: "John Doe", age: 30}
```

## Full Response with Usage

Access detailed token usage and cost information from any response:

```elixir
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")
text = ReqLLM.Response.text(response)
usage = ReqLLM.Response.usage(response)
# usage => %{input_tokens: 10, output_tokens: 8}
```

## Model Specifications

Specify models as strings, tuples, or structs with optional parameters:

```elixir
"anthropic:claude-haiku-4-5"
{:anthropic, "claude-3-sonnet-20240229", temperature: 0.7}
%ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet-20240229", temperature: 0.7}
```

## Key Management

Keys are loaded with clear precedence: per-request → in-memory → app config → env vars → .env files:

```elixir
# Recommended: .env files (automatically loaded via dotenvy at startup)
# Add to your .env file and they're picked up automatically:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...

# Alternative: Use ReqLLM.put_key for runtime in-memory storage
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.put_key(:openai_api_key, "sk-...")

# Per-request override (highest priority)
ReqLLM.generate_text("openai:gpt-4", "Hello", api_key: "sk-...")

# Alternative: Environment variables
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

# Alternative: Application configuration
Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-...")
```

## Message Context

Build multi-message conversations with system prompts and user messages:

```elixir
messages = [
  ReqLLM.Context.system("You are a helpful coding assistant"),
  ReqLLM.Context.user("Write a function to reverse a list")
]
ReqLLM.generate_text!("anthropic:claude-haiku-4-5", messages)
```

## Common Options

Control generation behavior with standard parameters:

```elixir
ReqLLM.generate_text!(
  "anthropic:claude-haiku-4-5",
  "Write code",
  temperature: 0.1,       # Control randomness (0.0-2.0)
  max_tokens: 1000,       # Limit response length
  system_prompt: "You are a helpful coding assistant"
)
```

## Available Providers

Run `mix req_llm.model_sync` for up-to-date list of supported models.
