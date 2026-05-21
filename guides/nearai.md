# NEAR AI Cloud

TEE-backed private inference through NEAR AI Cloud's OpenAI-compatible Chat Completions API.

## Configuration

```bash
NEARAI_API_KEY=your-api-key
```

Or programmatically:

```elixir
ReqLLM.put_key(:nearai_api_key, "your-api-key")
```

## Model Specs

NEAR AI Cloud model IDs use provider-style paths such as `anthropic/claude-haiku-4-5`.
Use the public catalog endpoint to inspect currently available models:

```bash
curl https://cloud-api.near.ai/v1/model/list
```

Then call a model with the `nearai:` prefix:

```elixir
ReqLLM.generate_text(
  "nearai:anthropic/claude-haiku-4-5",
  "Hello!"
)
```

If a model is not in the shared registry yet, a full explicit model spec also works:

```elixir
model =
  ReqLLM.model!(%{
    provider: :nearai,
    id: "openai/gpt-5.4-mini",
    base_url: "https://cloud-api.near.ai/v1"
  })

ReqLLM.generate_text(model, "Hello!")
```

## Compatibility Notes

NEAR AI Cloud uses the standard OpenAI Chat Completions request shape with Bearer token auth.
ReqLLM sends chat requests to `https://cloud-api.near.ai/v1/chat/completions`.

The provider translates `max_completion_tokens` to `max_tokens` because NEAR AI Cloud expects
the Chat Completions token limit field. Unsupported reasoning options are removed before the
request is sent, and strict tool schemas are sent without OpenAI's `strict` marker.

Streaming uses the same OpenAI-compatible SSE handling as other compatible providers.

## TEE Metadata

The model catalog includes per-model metadata such as `verifiable` and `attestationSupported`.
Use those fields when you need to distinguish TEE-verifiable models from proxied external models.

## Resources

- NEAR AI Cloud API base URL: `https://cloud-api.near.ai/v1`
- Public model catalog: `https://cloud-api.near.ai/v1/model/list`
- Model Specs Guide: [Model Specs](model-specs.md)
