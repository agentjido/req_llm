# Ollama (Local LLMs)

Run local LLMs with [Ollama](https://ollama.ai) using the OpenAI-compatible API.

## Prerequisites

1. Install Ollama from https://ollama.ai
2. Pull a model: `ollama pull llama3` or `ollama pull gemma2`
3. Ensure Ollama is running (default: `http://localhost:11434`)

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Ollama is a good example of the full explicit model specification path: the model may not exist in LLMDB, but ReqLLM can still use it as long as the model spec includes `provider`, `id`, and `base_url`.

## Native Provider (recommended)

As of req_llm 1.11, Ollama ships as a built-in provider. Use the `ollama:` prefix
directly — no custom provider setup required:

```elixir
ReqLLM.generate_text("ollama:llama3", "Hello!")

# With Ollama-specific options
ReqLLM.generate_text("ollama:gemma4:27b", "Hello",
  provider_options: [num_ctx: 16_384, keep_alive: "30m"]
)

# generate_object works out of the box
schema = [answer: [type: :string, required: true]]
ReqLLM.generate_object("ollama:llama3", "What is 2+2?", schema)
```

For jido_ai users, set a model alias in config and it resolves automatically:

```elixir
config :jido_ai, model_aliases: [default: "ollama:gemma4:27b"]
```

The existing model-struct approach (`provider: :openai, base_url: "..."`) continues to
work unchanged.

## Usage

Ollama exposes an OpenAI-compatible API, so use the `:openai` provider with a custom `base_url`:

```elixir
# Create a model struct for your Ollama model
model = ReqLLM.model!(%{id: "llama3", provider: :openai, base_url: "http://localhost:11434/v1"})

{:ok, response} = ReqLLM.generate_text(model, "Hello!")
```

### Streaming

```elixir
model = ReqLLM.model!(%{id: "gemma2", provider: :openai, base_url: "http://localhost:11434/v1"})

{:ok, stream} = ReqLLM.stream_text(model, "Write a haiku")

for chunk <- stream do
  IO.write(chunk.text || "")
end
```

## Helper Module

For convenience, create a wrapper module:

```elixir
defmodule MyApp.Ollama do
  @base_url "http://localhost:11434/v1"

  def generate_text(model_name, prompt, opts \\ []) do
    model = ReqLLM.model!(%{id: model_name, provider: :openai, base_url: @base_url})
    ReqLLM.generate_text(model, prompt, opts)
  end

  def stream_text(model_name, prompt, opts \\ []) do
    model = ReqLLM.model!(%{id: model_name, provider: :openai, base_url: @base_url})
    ReqLLM.stream_text(model, prompt, opts)
  end
end

# Usage
MyApp.Ollama.generate_text("llama3", "Explain pattern matching")
MyApp.Ollama.generate_text("gemma2", "Write a poem", temperature: 0.9)
```

## Common Models

| Model | Command | Notes |
|-------|---------|-------|
| Llama 3 | `ollama pull llama3` | Meta's latest, good general purpose |
| Gemma 2 | `ollama pull gemma2` | Google's efficient model |
| Mistral | `ollama pull mistral` | Fast, good for coding |
| CodeLlama | `ollama pull codellama` | Specialized for code |
| Phi-3 | `ollama pull phi3` | Microsoft's small but capable |

## Troubleshooting

- **Connection refused**: Ensure Ollama is running (`ollama serve`)
- **Model not found**: Pull the model first (`ollama pull <model>`)
- **Slow responses**: First request loads model into memory; subsequent requests are faster
- **Custom host**: Set `OLLAMA_HOST` environment variable or use different `base_url`

## Resources

- [Ollama Documentation](https://github.com/ollama/ollama/blob/main/README.md)
- [Available Models](https://ollama.ai/library)
