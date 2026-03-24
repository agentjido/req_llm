# LiteLLM

LiteLLM is an OpenAI-compatible proxy and gateway for routing requests across many underlying providers.

ReqLLM currently uses LiteLLM through its OpenAI-compatible chat-completions and embeddings surface.

## Configuration

```bash
LITELLM_API_KEY=sk-...
```

If your LiteLLM proxy does not enforce a master key, any non-empty placeholder value works because the proxy still expects an OpenAI-style bearer token field.

## Base URL

ReqLLM defaults LiteLLM to:

```elixir
"http://localhost:4000"
```

That matches the LiteLLM proxy quick-start examples. Override `:base_url` if your gateway is hosted elsewhere:

```elixir
ReqLLM.generate_text(
  "litellm:gpt-5",
  "Write a haiku about gateways",
  base_url: "https://litellm.example.com"
)
```

## Model Specs

LiteLLM models are usually proxy aliases from your `config.yaml`, such as `gpt-5`, `azure-gpt-4o`, or `anthropic-sonnet`.

String specs work directly:

```elixir
ReqLLM.generate_text("litellm:gpt-5", "Hello!")
```

Inline specs also work when you want to be explicit:

```elixir
model =
  ReqLLM.model!(%{
    provider: :litellm,
    id: "azure-gpt-4o",
    base_url: "https://litellm.example.com"
  })

ReqLLM.generate_text(model, "Hello!")
```

## Supported Operations

- chat generation
- structured output through the OpenAI-compatible tool path
- embeddings
- streaming chat responses

## Notes

- ReqLLM treats LiteLLM as an OpenAI-compatible proxy, so provider-specific LiteLLM admin APIs are out of scope for this provider module.
- Usage and cost data depend on what the LiteLLM proxy forwards in its OpenAI-compatible responses.

## Resources

- [LiteLLM Docs](https://docs.litellm.ai/)
- [LiteLLM GitHub](https://github.com/BerriAI/litellm)
