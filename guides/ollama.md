# Using Ollama (Local LLMs)

[Ollama](https://ollama.ai) provides an OpenAI-compatible API for running local LLMs. ReqLLM connects to Ollama servers using the `:openai` provider with a custom `base_url`.

## Prerequisites

1. Install Ollama from [ollama.ai](https://ollama.ai)
2. Pull a model: `ollama pull llama3` or `ollama pull gemma2`
3. Start the Ollama server (usually runs automatically on port 11434)

## Basic Usage

```elixir
{:ok, model} = ReqLLM.model("openai:llama3")
{:ok, response} = ReqLLM.generate_text(model, "Hello!", base_url: "http://localhost:11434/v1")
```

## Streaming

```elixir
{:ok, model} = ReqLLM.model("openai:llama3")
{:ok, stream} = ReqLLM.stream_text(model, "Write a poem", base_url: "http://localhost:11434/v1")

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
    {:ok, model} = ReqLLM.model("openai:#{model_name}")
    ReqLLM.generate_text(model, prompt, Keyword.put(opts, :base_url, @base_url))
  end

  def stream_text(model_name, prompt, opts \\ []) do
    {:ok, model} = ReqLLM.model("openai:#{model_name}")
    ReqLLM.stream_text(model, prompt, Keyword.put(opts, :base_url, @base_url))
  end
end

# Usage
MyApp.Ollama.generate_text("llama3", "Explain quantum computing")
```

## Common Ollama Models

| Model | Command | Description |
|-------|---------|-------------|
| Llama 3 | `ollama pull llama3` | Meta's latest open model |
| Llama 3.2 | `ollama pull llama3.2` | Latest Llama with vision |
| Gemma 2 | `ollama pull gemma2` | Google's efficient model |
| Mistral | `ollama pull mistral` | Fast 7B model |
| Qwen 2 | `ollama pull qwen2` | Alibaba's multilingual model |
| Phi-3 | `ollama pull phi3` | Microsoft's small model |
| DeepSeek Coder | `ollama pull deepseek-coder` | Code-focused model |

Run `ollama list` to see installed models.

## Troubleshooting

### Connection Refused

Ensure Ollama is running:

```bash
ollama serve
```

### Model Not Found

Pull the model first:

```bash
ollama pull llama3
```

### Slow Responses

- Ensure you have sufficient RAM for the model size
- Use smaller quantized versions (e.g., `llama3:8b-q4_0`)
- Check GPU acceleration is enabled: `ollama run llama3 --verbose`

### Custom Ollama Host

If Ollama runs on a different host or port:

```elixir
base_url: "http://192.168.1.100:11434/v1"
```

## Resources

- [Ollama Website](https://ollama.ai)
- [Ollama Model Library](https://ollama.com/library)
- [Ollama GitHub](https://github.com/ollama/ollama)
