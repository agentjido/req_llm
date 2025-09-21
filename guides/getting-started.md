# Getting Started

## Installation

```elixir
def deps do
  [
    {:req_llm, "~> 1.0.0-rc.1"}
  ]
end
```

## Generate Text

```elixir
# Configure your API key 
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.generate_text!("anthropic:claude-3-sonnet", "Hello")
# Returns: "Hello! How can I assist you today?"

ReqLLM.stream_text!("anthropic:claude-3-sonnet", "Tell me a story")
|> Enum.each(&IO.write/1)
```

## Structured Data

```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]
{:ok, object} = ReqLLM.generate_object("anthropic:claude-3-sonnet", "Generate a person", schema)
# Returns: %{name: "John Doe", age: 30}
```

## Full Response with Usage

```elixir
{:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", "Hello")
text = ReqLLM.Response.text(response)
usage = ReqLLM.Response.usage(response)
# usage => %{input_tokens: 10, output_tokens: 8}
```

## Model Specifications

```elixir
"anthropic:claude-3-sonnet"
{:anthropic, "claude-3-sonnet", temperature: 0.7}
%ReqLLM.Model{provider: :anthropic, model: "claude-3-sonnet", temperature: 0.7}
```

## Key Management

ReqLLM provides flexible API key configuration with clear precedence:

```elixir
# Recommended: Use ReqLLM.put_key for secure in-memory storage
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.put_key(:openai_api_key, "sk-...")

# Per-request override (highest priority)
ReqLLM.generate_text("openai:gpt-4", "Hello", api_key: "sk-...")

# Alternative: Environment variables
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

# Alternative: Application configuration
Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-...")

# Keys from .env are automatically loaded via JidoKeys
# Just add to your .env file and they're picked up automatically:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
```

## Message Context

```elixir
messages = [
  ReqLLM.Context.system("You are a helpful coding assistant"),
  ReqLLM.Context.user("Write a function to reverse a list")
]
ReqLLM.generate_text!("anthropic:claude-3-sonnet", messages)
```

## Common Options

```elixir
ReqLLM.generate_text!(
  "anthropic:claude-3-sonnet",
  "Write code",
  temperature: 0.1,      # Control randomness (0.0-2.0)
  max_tokens: 1000       # Limit response length
)
```

## Available Providers

Run `mix req_llm.model_sync` for up-to-date list of supported models.
