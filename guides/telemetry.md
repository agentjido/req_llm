# Telemetry

ReqLLM emits native `:telemetry` events for both Req-backed requests and Finch-backed streaming. Every event for a logical request shares the same `request_id`, so you can correlate request lifecycle, reasoning lifecycle, and token usage without provider-specific parsing.

Use these events for billing, tenant attribution, latency tracking, reasoning observability, and low-level integrations that cannot rely on wrapping Req directly.

## Event Families

- `[:req_llm, :request, :start]` fires once when a request begins.
- `[:req_llm, :request, :stop]` fires once when a request completes, including streaming completion and cancellation.
- `[:req_llm, :request, :exception]` fires once when a request fails.
- `[:req_llm, :reasoning, :start]` fires when the effective request enables provider reasoning.
- `[:req_llm, :reasoning, :update]` fires on reasoning milestones, not every chunk.
- `[:req_llm, :reasoning, :stop]` fires when a reasoning request finishes, is cancelled, or errors.
- `[:req_llm, :token_usage]` remains as a compatibility event for token and cost tracking.

Request lifecycle events always include a `reasoning` map in metadata, even for operations that do not support reasoning. In those cases, the snapshot is explicit about reasoning being disabled or unsupported.

## Measurements

- `request.start`, `reasoning.start`, and `reasoning.update` emit `%{system_time: integer}`.
- `request.stop`, `request.exception`, and `reasoning.stop` emit `%{duration: integer, system_time: integer}`.

`duration` is in native monotonic time units and should be converted with `System.convert_time_unit/3` if you want milliseconds.

## Request Metadata

Every request lifecycle event includes these core metadata fields:

- `request_id`
- `operation`
- `mode`
- `provider`
- `model`
- `transport`
- `reasoning`
- `request_summary`
- `response_summary`
- `http_status`
- `finish_reason`
- `usage`

When payload capture is enabled, request lifecycle events also include `request_payload` and `response_payload`.

Typical request metadata looks like this:

```elixir
%{
  request_id: "2184",
  operation: :chat,
  mode: :stream,
  provider: :anthropic,
  model: %LLMDB.Model{},
  transport: :finch,
  reasoning: %{
    supported?: true,
    requested?: true,
    effective?: true,
    requested_mode: :enabled,
    requested_effort: :medium,
    requested_budget_tokens: 4096,
    effective_mode: :enabled,
    effective_effort: :medium,
    effective_budget_tokens: 4096,
    returned_content?: true,
    reasoning_tokens: 812,
    content_bytes: 1432,
    channel: :content_and_usage
  },
  request_summary: %{
    message_count: 1,
    text_bytes: 42,
    image_part_count: 0,
    tool_call_count: 0
  },
  response_summary: %{
    text_bytes: 318,
    thinking_bytes: 1432,
    tool_call_count: 0,
    image_count: 0,
    object?: false
  },
  http_status: 200,
  finish_reason: :stop,
  usage: %{
    input_tokens: 24,
    output_tokens: 133,
    total_tokens: 157,
    reasoning_tokens: 812
  }
}
```

`request_summary` and `response_summary` are compact by design. Their exact shape varies by operation:

- Chat, object, and image requests summarize message count, text bytes, image parts, and tool calls.
- Chat, object, and image responses summarize output text bytes, thinking bytes, tool calls, image count, and structured object presence.
- Embeddings summarize input count, vector count, and dimensions.
- Speech summarizes input text bytes and output audio size and format.
- Transcription summarizes input audio size plus transcript text bytes, segment count, and duration.

## Standardized Reasoning Metadata

The `reasoning` map is the provider-neutral contract for reasoning and thinking observability:

- `supported?` says whether the operation and model support reasoning.
- `requested?` reflects the original API options passed to ReqLLM.
- `effective?` reflects the translated provider request after normalization.
- `requested_mode`, `requested_effort`, and `requested_budget_tokens` capture the caller intent.
- `effective_mode`, `effective_effort`, and `effective_budget_tokens` capture what the provider request actually used.
- `returned_content?` indicates whether reasoning content was observed.
- `reasoning_tokens` tracks normalized reasoning token usage when providers expose it.
- `content_bytes` tracks the amount of reasoning content observed without exposing the content itself.
- `channel` is one of `:none`, `:usage_only`, `:content_only`, or `:content_and_usage`.

Requested reasoning is normalized from the original ReqLLM options, such as:

- `reasoning_effort`
- `thinking: %{type: "enabled", budget_tokens: ...}`
- `provider_options: [google_thinking_budget: ...]`
- provider-specific reasoning budget and thinking toggles

Effective reasoning is normalized from the translated provider request so that OpenAI, Anthropic, Google, Vertex, and other providers can be compared through the same telemetry shape.

The normalizer currently covers these provider request shapes:

- OpenAI-style reasoning effort fields such as `reasoning.effort` and `reasoning_effort` on OpenAI, OpenRouter, Groq, and xAI
- Anthropic-style thinking fields such as `thinking` and `additional_model_request_fields.thinking` on Anthropic, Azure Claude, Bedrock Claude, and Vertex Claude
- Google-style thinking budgets such as `google_thinking_budget` and `generationConfig.thinkingConfig.thinkingBudget` on Google Gemini and Vertex Gemini
- Alibaba `enable_thinking` and `thinking_budget`
- Zenmux `reasoning.enable`, `reasoning.depth`, and `reasoning_effort`
- Z.AI `thinking.type`

Because `requested` is derived from the original ReqLLM call and `effective` is derived from the translated provider request, they can diverge when provider translation drops, disables, or rewrites a reasoning configuration.

When callers send conflicting reasoning controls, ReqLLM telemetry resolves them conservatively. Explicit disable signals such as `thinking: %{type: "disabled"}`, `reasoning_effort: :none`, or zero-token budgets win over enable hints in the normalized `requested` snapshot.

## Reasoning Milestones

Reasoning events never include raw thinking text. They are metadata-only, even when payload capture is enabled.

`reasoning.update` is emitted only for milestone transitions:

- `milestone: :content_started` when the first reasoning content is observed
- `milestone: :usage_updated` when reasoning token usage first appears or changes
- `milestone: :details_available` when provider reasoning details become available

`reasoning.start` uses `milestone: :request_started`.

`reasoning.stop` uses the terminal outcome as its milestone, for example:

- `:stop`
- `:length`
- `:tool_calls`
- `:cancelled`
- `:incomplete`
- `:error`
- `:unknown`

## Token Usage Compatibility Event

`[:req_llm, :token_usage]` remains available for existing consumers and now fires for streaming as well as non-streaming requests.

Measurements include:

- `input_tokens`
- `output_tokens`
- `total_tokens`
- `input_cost`
- `output_cost`
- `total_cost`
- `reasoning_tokens`

Metadata includes:

- `model`
- `request_id`
- `operation`
- `mode`
- `provider`
- `transport`

For new integrations, prefer `[:req_llm, :request, :stop]` as the source of truth because it includes duration, finish reason, summaries, and normalized reasoning metadata alongside usage.

## Attaching Telemetry Handlers

```elixir
defmodule MyApp.ReqLLMObserver do
  require Logger

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception],
    [:req_llm, :reasoning, :start],
    [:req_llm, :reasoning, :update],
    [:req_llm, :reasoning, :stop],
    [:req_llm, :token_usage]
  ]

  def attach do
    :telemetry.attach_many("my-app-req-llm", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:req_llm, :request, :stop], %{duration: duration}, metadata, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info(
      "req_llm request=#{metadata.request_id} model=#{metadata.model.provider}:#{metadata.model.id} " <>
        "duration_ms=#{duration_ms} finish_reason=#{inspect(metadata.finish_reason)} " <>
        "total_tokens=#{metadata.usage && metadata.usage.total_tokens}"
    )
  end

  def handle_event([:req_llm, :reasoning, :update], _measurements, metadata, _config) do
    Logger.debug(
      "req_llm reasoning request=#{metadata.request_id} milestone=#{inspect(metadata.milestone)} " <>
        "channel=#{inspect(metadata.reasoning.channel)} tokens=#{metadata.reasoning.reasoning_tokens}"
    )
  end

  def handle_event([:req_llm, :token_usage], measurements, metadata, _config) do
    Logger.info(
      "req_llm usage request=#{metadata.request_id} total_tokens=#{measurements.total_tokens} " <>
        "total_cost=#{measurements.total_cost}"
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
```

## Payload Capture

By default, ReqLLM telemetry is metadata-only:

```elixir
config :req_llm, telemetry: [payloads: :none]
```

You can opt into payload capture globally:

```elixir
config :req_llm, telemetry: [payloads: :raw]
```

Or per request:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", telemetry: [payloads: :raw])

ReqLLM.stream_text("openai:gpt-5-mini", "Hello", telemetry: [payloads: :raw])
```

Payload mode only affects request lifecycle events. Reasoning events stay metadata-only.

Raw payload mode is still sanitized:

- reasoning and thinking text is redacted from payloads
- tools are emitted as stable metadata only (`name`, `description`, `strict`, `parameter_schema`)
- binary message parts such as images and files are summarized by byte size, media type, and filename instead of emitting raw bytes
- unknown payload shapes are recursively sanitized so opaque binaries are summarized instead of passed through
- speech telemetry reports audio size and format, not raw audio bytes
- embedding telemetry reports vector counts and dimensions, not the vectors themselves
- transcription telemetry stays structured and avoids opaque binary payloads

Use raw payload capture carefully in multi-tenant systems because request and response payloads may still contain user content, tool call arguments, and structured outputs.

## OpenTelemetry Bridge

ReqLLM also includes a small OpenTelemetry bridge in `ReqLLM.OpenTelemetry`.
It turns the normalized request lifecycle telemetry above into GenAI client spans
without adding provider-specific instrumentation paths.

Attach it once during application startup:

```elixir
case ReqLLM.OpenTelemetry.attach() do
  :ok -> :ok
  {:error, :opentelemetry_unavailable} -> :ok
end
```

The bridge uses:

- `gen_ai.provider.name`
- `gen_ai.operation.name`
- `gen_ai.request.model`
- `gen_ai.output.type`
- `gen_ai.response.finish_reasons`
- `gen_ai.usage.input_tokens`
- `gen_ai.usage.output_tokens`
- cache read and cache creation token attributes when available
- `error.type` for failed requests

ReqLLM does not configure an SDK or exporter for you. To export traces, your host
application still needs normal OpenTelemetry setup, such as `:opentelemetry`
and an exporter dependency.

For advanced integrations, ReqLLM also exposes a dependency-free mapper in
`ReqLLM.Telemetry.OpenTelemetry`. It builds span stubs from ReqLLM telemetry
metadata without attaching handlers or depending on an OpenTelemetry SDK.

```elixir
defmodule MyApp.ReqLLMOpenTelemetry do
  alias ReqLLM.Telemetry.OpenTelemetry

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception]
  ]

  def attach do
    :telemetry.attach_many("my-app-req-llm-otel", @events, &__MODULE__.handle_event/4, %{})
  end

  def handle_event([:req_llm, :request, :start], _measurements, metadata, _config) do
    stub = OpenTelemetry.request_start(metadata, content: :attributes)
    MyApp.Tracing.start_gen_ai_span(metadata.request_id, stub)
  end

  def handle_event([:req_llm, :request, :stop], _measurements, metadata, _config) do
    stub = OpenTelemetry.request_stop(metadata, content: :attributes)
    MyApp.Tracing.finish_gen_ai_span(metadata.request_id, stub)
  end

  def handle_event([:req_llm, :request, :exception], _measurements, metadata, _config) do
    stub = OpenTelemetry.request_exception(metadata, content: :attributes)
    MyApp.Tracing.finish_gen_ai_span(metadata.request_id, stub)
  end
end
```

The low-level mapper includes richer normalized GenAI metadata such as:

- `gen_ai.response.id`
- `gen_ai.response.model`
- `gen_ai.input.messages` and `gen_ai.output.messages` when content capture is enabled
- tool call and tool result payloads in message parts
- exception event payloads for manual span finishing

## Coverage Across APIs

These event families are emitted for:

- high-level sync APIs like `ReqLLM.generate_text/3`, `ReqLLM.generate_object/4`, `ReqLLM.generate_image/3`, `ReqLLM.embed/3`, `ReqLLM.transcribe/3`, and `ReqLLM.speak/3`
- high-level streaming APIs like `ReqLLM.stream_text/3` and `ReqLLM.stream_object/4`
- low-level Req-backed flows using `provider_module.prepare_request/4` followed by `Req.request/1`
- low-level streaming flows using `ReqLLM.Streaming.start_stream/4`

If you need observability that covers both sync and streaming, attach to ReqLLM telemetry rather than Req middleware alone.

## See Also

- [Usage & Billing](usage-and-billing.md)
- [Configuration](configuration.md)
- [Core Concepts](core-concepts.md)
