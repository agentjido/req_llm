# Inference.net

ReqLLM uses the Inference.net OpenAI-compatible Chat Completions API.

## Configuration

Create an Inference.net API key and set it in the environment:

```bash
export INFERENCE_API_KEY="your-api-key"
```

ReqLLM uses `https://api.inference.net/v1` by default. For US-only processing,
set `base_url: "https://us.api.inference.net/v1"` on a request or in the
`:inference` application configuration.

## Text and streaming

Use the exact model ID from the Inference.net model catalog:

```elixir
ReqLLM.generate_text("inference:glm-5.3-flash", "Explain this code")

ReqLLM.stream_text("inference:deepseek-v4.1-flash-1017", "Solve this problem",
  reasoning_effort: :high,
  max_tokens: 20_000
)
```

The LLMDB catalog is built from the public `GET /v1/models` endpoint. It stores
the model context limit, output limit, reasoning levels, modalities, endpoint
support, prices, and privileged-access flag.

## Structured output

Inference.net supports native JSON Schema output. `ReqLLM.generate_object/4`
uses this mode and sends a strict schema.

## Observability headers

Use provider options to add Inference.net request labels:

```elixir
ReqLLM.generate_text("inference:gpt-5-mini", "Hello",
  provider_options: [
    inference_environment: "production",
    inference_task_id: "support-agent",
    inference_metadata: %{
      "user-id" => "user-123",
      "conversation-id" => "conversation-456"
    }
  ]
)
```

These options send `x-inference-environment`, `x-inference-task-id`, and
`x-inference-metadata-*` headers.

## Priority service

Some models have a faster service tier. Send `service_tier: "priority"` or
`service_tier: "fast"` in the provider options. The available tier and price
depend on the model.

## Privileged models

Some model records have the `"privileged"` tag and
`extra["requires_approved_access"] == true`. An API key is not sufficient for
these models until Inference.net approves access for the team.

After approval, use a privileged model through the same provider:

```elixir
ReqLLM.generate_text(
  "inference:deepseek-v4.1-flash-1017-cyber",
  "Hello"
)
```

The fixture suite does not record this privileged model.

## Current limits

ReqLLM uses Chat Completions for this provider. The separate Inference.net
gateway mode for forwarding a second provider key is not part of this provider.
Use a direct provider integration when the upstream provider must bill the
request.

The fixture suite has 27 recordings across three models:

- `gpt-5-nano`: text, streaming, usage, token limits, reasoning, strict tool
  round trips, and strict structured output.
- `deepseek-v4.1-flash-1017`: the same checks plus image input.
- `llama-3.2-1b-instruct`: basic text, streaming, usage, token limits, and
  multi-turn context without tool or reasoning claims.

Replay these tests without a live request:

```bash
mix test test/coverage/inference/comprehensive_test.exs --include coverage
```

Set `REQ_LLM_FIXTURES_MODE=record` and `INFERENCE_API_KEY` to replace the
recordings with new live responses.
