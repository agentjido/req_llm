# Meta Model API

ReqLLM connects directly to Meta's Model API at `https://api.meta.ai/v1` and
uses its OpenAI-compatible Responses API.

## Configuration

Create a Meta Model API key and expose it as:

```bash
MODEL_API_KEY=your-api-key
```

ReqLLM also accepts the standard per-request `api_key:` option.

## Basic Usage

```elixir
ReqLLM.generate_text(
  "meta:muse-spark-1.1",
  "Explain OTP supervision trees in a paragraph",
  reasoning_effort: :low,
  max_tokens: 512
)
```

ReqLLM translates `max_tokens` to the Responses API `max_output_tokens` field.

## Streaming

```elixir
{:ok, response} =
  ReqLLM.stream_text(
    "meta:muse-spark-1.1",
    "Work through this problem carefully",
    reasoning_effort: :high,
    max_tokens: 1024
  )

ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&IO.write/1)
|> Stream.run()
```

## Reasoning Continuity

Meta requests default to stateless operation with:

```json
{
  "store": false,
  "include": ["reasoning.encrypted_content"]
}
```

ReqLLM preserves returned encrypted reasoning items in the assistant message and
replays them on later turns. This keeps reasoning context intact through tool
calls without relying on server-side response storage.

Set `provider_options: [store: true]` to opt into server-side storage. You can
also override `include`, although removing encrypted reasoning content prevents
stateless reasoning replay.

## Provider Options

Meta-specific fields belong under `provider_options`:

```elixir
ReqLLM.generate_text(
  "meta:muse-spark-1.1",
  "Summarize the conversation",
  provider_options: [
    prompt_cache_retention: "24h",
    parallel_tool_calls: false,
    reasoning_summary: :auto
  ]
)
```

Supported provider options are:

- `include` — additional Responses API data to return
- `max_output_tokens` — Meta's native output-token limit field
- `parallel_tool_calls` — allow multiple tool requests in one response
- `prompt_cache_retention` — `"in_memory"` or `"24h"`
- `reasoning_summary` — `:auto`, `:concise`, or `:detailed`
- `response_format` — an OpenAI-compatible JSON schema response format
- `store` — allow server-side response storage

Canonical `reasoning_effort` values `:minimal`, `:low`, `:medium`, `:high`, and
`:xhigh` are sent to Meta. Muse does not accept `:none`, so ReqLLM maps it to
`:minimal`. Meta does not expose a reasoning token budget; ReqLLM removes
`reasoning_token_budget` with the configured unsupported-option policy.

## Tools and Structured Output

The provider uses ReqLLM's standard tool schema and the Responses API JSON
schema output format. `tools`, `tool_choice`, `generate_object/4`, and their
streaming equivalents therefore use the same high-level APIs as other ReqLLM
providers.

## Live Compatibility Recording

The comprehensive provider suite can be recorded after `MODEL_API_KEY` is set:

```bash
mix mc "meta:muse-spark-1.1" --record
```

## Llama Models Hosted Elsewhere

The `meta` provider targets Meta's direct Model API. Llama models hosted by
OpenRouter, Groq, Azure, Vertex AI, Ollama, or another service should use that
service's ReqLLM provider and model ID.

AWS Bedrock's native Llama payload remains supported by
`ReqLLM.Providers.AmazonBedrock.Meta`, backed by the internal
`ReqLLM.Providers.Meta.Llama` formatter.

## Resources

- [Meta Model API documentation](https://ai.developer.meta.com/docs)
- [Models](https://ai.developer.meta.com/docs/getting-started/models)
- [Authentication](https://ai.developer.meta.com/docs/getting-started/authentication)
- [Pricing and rate limits](https://ai.developer.meta.com/docs/getting-started/pricing-rate-limits)
