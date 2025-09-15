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

ReqLLM uses JidoKeys for secure API key storage with automatic .env pickup:

```elixir
# Option 1: Set keys directly  
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
ReqLLM.put_key("OPENAI_API_KEY", "sk-...")

# Option 2: Keys from .env are automatically loaded via JidoKeys+Dotenvy
# Just add to your .env file:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...

# Providers automatically retrieve keys from JidoKeys
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

Run `mix req_llm.models` for up-to-date list of supported models.
