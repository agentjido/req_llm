# Ollama (Local LLMs)

Run local LLMs with [Ollama](https://ollama.ai) using the OpenAI-compatible API.

## Prerequisites

1. Install Ollama from https://ollama.ai
2. Pull a model: `ollama pull llama3` or `ollama pull gemma2`
3. Ensure Ollama is running (default: `http://localhost:11434`)

## Usage

Ollama exposes an OpenAI-compatible API, so use the `:openai` provider with a custom `base_url`:

```elixir
# Create a model struct for your Ollama model
{:ok, model} = ReqLLM.model(%{id: "llama3", provider: :openai})

# Generate text with custom base_url
{:ok, response} = ReqLLM.generate_text(model, "Hello!", base_url: "http://localhost:11434/v1")
```

### Streaming

```elixir
{:ok, model} = ReqLLM.model(%{id: "gemma2", provider: :openai})

{:ok, stream} = ReqLLM.stream_text(model, "Write a haiku", base_url: "http://localhost:11434/v1")

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
    {:ok, model} = ReqLLM.model(%{id: model_name, provider: :openai})
    ReqLLM.generate_text(model, prompt, Keyword.put(opts, :base_url, @base_url))
  end

  def stream_text(model_name, prompt, opts \\ []) do
    {:ok, model} = ReqLLM.model(%{id: model_name, provider: :openai})
    ReqLLM.stream_text(model, prompt, Keyword.put(opts, :base_url, @base_url))
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
