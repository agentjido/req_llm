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
- `request_options`
- `server`
- `streaming`

When payload capture is enabled, request lifecycle events also include `request_payload` and `response_payload`.

`request_options` is a compact map of normalized inference parameters extracted from the original call: `temperature`, `top_p`, `top_k`, `max_tokens`, `frequency_penalty`, `presence_penalty`, `stop_sequences`, `seed`, `n` (choice count), `stream?`, `encoding_formats`, `conversation_id`, and `service_tier`. Keys whose value is `nil` are dropped.

`server` is a map of the resolved upstream endpoint: `address`, `port`, and `path`. It is empty before the request is dispatched and populated by the time `:stop` or `:exception` fires.

`streaming` is set on streaming requests only and exposes `first_chunk_at` (a `System.monotonic_time/0` reading) and `time_to_first_chunk` (in `:native` units, measured from request start to the first non-empty content chunk). Both are `nil` until ReqLLM observes the first content chunk via `ReqLLM.Telemetry.observe_stream_chunk/2`.

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
  },
  request_options: %{
    temperature: 0.7,
    max_tokens: 1024,
    stream?: true,
    conversation_id: "thread-42"
  },
  server: %{
    address: "api.anthropic.com",
    port: 443,
    path: "/v1/messages"
  },
  streaming: %{
    first_chunk_at: -576_460_751_000_000_000,
    time_to_first_chunk: 412_300_000
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

The `telemetry:` option also accepts a `:conversation_id` string, which flows through to `request_options.conversation_id` and to the `gen_ai.conversation.id` span attribute on the OpenTelemetry bridge:

```elixir
ReqLLM.generate_text(model, prompt, telemetry: [conversation_id: "thread-42"])
```

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

The bridge follows the [OpenTelemetry GenAI semantic conventions][otel-gen-ai].
On span start it sets:

- `gen_ai.provider.name` (spec enum where defined; stringified atom otherwise)
- `gen_ai.operation.name` (`chat`, `embeddings`, `generate_content`, …)
- `gen_ai.request.model`
- `gen_ai.output.type` (`text`, `json`, `image`, `speech` — operation-dependent)
- `gen_ai.request.temperature`, `top_p`, `top_k`, `max_tokens`
- `gen_ai.request.frequency_penalty`, `presence_penalty`
- `gen_ai.request.stop_sequences`, `seed`
- `gen_ai.request.choice.count` (from the `:n` option)
- `gen_ai.request.stream` (`true` for `stream_text`/`stream_object`)
- `gen_ai.request.encoding_formats` (embeddings)
- `gen_ai.conversation.id` when the caller passes `telemetry: [conversation_id: …]`
- `server.address` and `server.port` resolved from the underlying `Req.Request.url`

On span stop it sets:

- `gen_ai.response.finish_reasons`
- `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`
- `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_creation.input_tokens` when available
- `gen_ai.usage.reasoning.output_tokens` when reasoning tokens are reported
- `gen_ai.usage.cost` (USD) when ReqLLM has computed a cost breakdown
- `gen_ai.embeddings.dimension.count` for embedding responses
- `error.type` and span status `:error` when the response carries `http_status >= 400`

On span exception it sets `error.type` and adds an exception event.

For streaming requests, the bridge also sets
`gen_ai.response.time_to_first_chunk` (seconds) on the stop span — measured
from request start to the first non-empty content chunk observed by
`ReqLLM.Telemetry.observe_stream_chunk/2`.

[otel-gen-ai]: https://opentelemetry.io/docs/specs/semconv/gen-ai/

#### Metrics

When the OpenTelemetry metrics API is available alongside the tracer, the
bridge also records spec histograms via the same adapter. No extra
configuration is needed beyond a working OTel meter provider in your host
app:

| Metric                                              | When        | Notes                                    |
|-----------------------------------------------------|-------------|------------------------------------------|
| `gen_ai.client.operation.duration` (s)              | stop + ex   | sets `error.type` on failures            |
| `gen_ai.client.token.usage` ({token})               | stop        | one record per `gen_ai.token.type`       |
| `gen_ai.client.operation.time_to_first_chunk` (s)   | streaming   | from first non-empty content chunk       |
| `gen_ai.client.operation.time_per_output_chunk` (s) | streaming   | `(duration − TTFC) / output_tokens`      |

Each histogram is created lazily with the OpenTelemetry GenAI spec bucket
boundaries — `[0.01, 0.02, 0.04, …, 81.92]` for durations and
`[1, 4, 16, …, 67_108_864]` for token counts. Per-record attributes follow
the spec: `gen_ai.operation.name`, `gen_ai.provider.name`,
`gen_ai.request.model`, `gen_ai.response.model`, `server.address`,
`server.port`.

If the meter API is unavailable (e.g. you only depend on the tracer SDK),
the bridge silently skips metrics emission while continuing to record spans.

#### Capturing message content (opt-in)

By default the bridge does **not** attach prompt or response content. To
promote structured messages, system instructions, and tool definitions, pass
the `:content` option and enable raw payload capture on the calls you want
to record:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", content: :attributes)

ReqLLM.generate_text(model, prompt, telemetry: [payloads: :raw])
```

The `:content` option matches the dependency-free mapper:

- `:none` (default) — no message, instructions, or tool definitions are
  emitted.
- `:attributes` (alias: `true`) — sets `gen_ai.input.messages`,
  `gen_ai.system_instructions`, `gen_ai.tool.definitions`, and
  `gen_ai.output.messages` as span attributes.
- `:event` — bundles the same payload into a single
  `gen_ai.client.inference.operation.details` span event on the terminal
  lifecycle event instead of attaching it to attributes.

The captured fields are:

- `gen_ai.system_instructions` — text-only parts from system messages
- `gen_ai.input.messages` — non-system input messages with tool calls and
  tool results expressed as part records
- `gen_ai.tool.definitions` — `[%{"type" => "function", "name" => …, …}, …]`
  derived from `Context.tools`
- `gen_ai.output.messages` — assistant response with `finish_reason`

Reasoning text never appears in any of these, even if the underlying model
returned thinking parts. ReqLLM's payload sanitizer redacts reasoning before
the bridge sees the messages, and the OTel content mapper additionally
filters part types to `text` and `image_url` only.

#### OpenAI provider extensions

For OpenAI-family providers (`openai`, `openai_codex`, `azure`) the bridge
also emits the spec's [OpenAI extension attributes][otel-openai] when ReqLLM
has the data:

- `openai.api.type` — `"chat_completions"`, `"responses"`, or `"embeddings"`,
  inferred from the request URL path
- `openai.request.service_tier` — when the caller passed `service_tier:` (or
  `provider_options: [service_tier: …]`)
- `openai.response.service_tier` — when the response body carried it
- `openai.response.system_fingerprint` — when the response body carried it

Capturing the response-side fields requires `telemetry: [payloads: :raw]` on
the call so the bridge can read `provider_meta` from the parsed response.

[otel-openai]: https://opentelemetry.io/docs/specs/semconv/gen-ai/openai/

#### Cost capture

When ReqLLM has computed a USD cost breakdown for a request, the bridge sets
`gen_ai.usage.cost` (number, USD total) on the stop span. Cost lookup uses
the same model pricing tables as `[:req_llm, :token_usage]`.

Pass `langfuse: true` to `attach/2` to additionally emit
`langfuse.observation.cost_details` — a JSON string with the per-bucket
breakdown (`input`, `output`, `reasoning`, `total`). Langfuse uses this to
render cost details on a generation. The attribute is dropped silently when
no cost data is available, so it's safe to leave on globally:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", langfuse: true)
```

#### Provider name mapping

| ReqLLM provider | `gen_ai.provider.name` |
|-----------------|------------------------|
| `:openai`       | `openai`               |
| `:anthropic`    | `anthropic`            |
| `:azure`        | `azure.ai.openai`      |
| `:google`       | `gcp.gen_ai`           |
| `:google_vertex`| `gcp.vertex_ai`        |
| `:amazon_bedrock` | `aws.bedrock`        |
| `:groq`         | `groq`                 |
| `:xai`          | `x_ai`                 |
| `:deepseek`     | `deepseek`             |

Other providers (`alibaba`, `cerebras`, `meta`, `openrouter`, `vllm`, `zai`,
`zenmux`, `venice`, `minimax`, …) are stringified verbatim from their atom
name.

#### Operation name mapping

| ReqLLM operation | `gen_ai.operation.name` | `gen_ai.output.type` |
|------------------|-------------------------|----------------------|
| `:chat`          | `chat`                  | `text`               |
| `:object`        | `chat`                  | `json`               |
| `:embedding`     | `embeddings`            | _(not set)_          |
| `:image`         | `generate_content`      | `image`              |
| `:speech`        | `speech` *              | `speech`             |
| `:transcription` | `transcription` *       | `text`               |

\* Non-spec operations (`speech`, `transcription`, `rerank`) are stringified
unchanged. Revisit if the spec adds enum values for them later.

#### Sending traces to Langfuse

[Langfuse][langfuse-otel] consumes ReqLLM's GenAI spans natively over OTLP
HTTP. ReqLLM does not configure the SDK for you — you point your existing
OTel pipeline at one of Langfuse's endpoints:

| Region   | OTLP HTTP endpoint                                         |
|----------|------------------------------------------------------------|
| EU       | `https://cloud.langfuse.com/api/public/otel`               |
| US       | `https://us.cloud.langfuse.com/api/public/otel`            |
| Japan    | `https://jp.cloud.langfuse.com/api/public/otel`            |
| HIPAA US | `https://hipaa.cloud.langfuse.com/api/public/otel`         |

Langfuse only accepts OTLP/HTTP today — gRPC is not supported.

Auth uses HTTP basic auth with your project keys, base64-encoded:

```elixir
auth = "Basic " <> Base.encode64("#{public_key}:#{secret_key}")

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_traces_endpoint: "https://us.cloud.langfuse.com/api/public/otel/v1/traces",
  otlp_traces_headers: [{"authorization", auth}]
```

For per-trace user/session attribution, install the OpenTelemetry
`BaggageSpanProcessor` in your tracer setup so OTel baggage entries like
`langfuse.user.id` and `langfuse.session.id` are copied onto the spans
ReqLLM emits. ReqLLM itself does not set them — they're caller context.

For minimum-friction integration, attach with both content and Langfuse:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel",
  content: :attributes,
  langfuse: true
)
```

Then make calls with raw payload telemetry on:

```elixir
ReqLLM.generate_text(model, prompt,
  telemetry: [payloads: :raw, conversation_id: "thread-42"]
)
```

Langfuse will then show model, cost (with breakdown), input/output token
counts, conversation/session ids, and the structured input/output messages
including tool calls.

[langfuse-otel]: https://langfuse.com/integrations/native/opentelemetry

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

The low-level mapper emits the same `gen_ai.*` and `server.*` attribute set as
the auto-attach bridge (provider/operation/output type, request parameters,
server, usage, finish reasons, reasoning tokens, embedding dimension count,
HTTP error type), plus richer normalized response and content metadata such as:

- `gen_ai.response.id`
- `gen_ai.response.model`
- `gen_ai.input.messages` (without system messages — those move to
  `gen_ai.system_instructions`)
- `gen_ai.system_instructions` and `gen_ai.tool.definitions`
- `gen_ai.output.messages` with finish reasons
- tool call and tool result payloads in message parts
- exception event payloads for manual span finishing

Pass one of three content modes:

- `content: :none` (default) — only scalar `gen_ai.*` attributes
- `content: :attributes` — content fields above are set on the span
- `content: :event` — same payload, but bundled into a single
  `gen_ai.client.inference.operation.details` span event instead of attributes

Pass `langfuse: true` to also emit `langfuse.observation.cost_details` (a
JSON string) on the stop span when ReqLLM has computed a cost breakdown.

Pass `measurements: %{duration: native}` to populate the `metrics` field on
the returned stub. Records use the same shape and bucket boundaries as the
auto-bridge:

```elixir
def handle_event([:req_llm, :request, :stop], measurements, metadata, _config) do
  stub =
    OpenTelemetry.request_stop(metadata,
      content: :attributes,
      measurements: measurements
    )

  Enum.each(stub.metrics, &MyApp.Tracing.record_genai_histogram/1)
  MyApp.Tracing.finish_gen_ai_span(metadata.request_id, stub)
end
```

Streaming requests also surface `gen_ai.response.time_to_first_chunk` in
`stub.attributes` when ReqLLM observed a non-empty content chunk during the
stream.

Both surfaces share the same internal name table and content shaper, so
provider/operation/output values and message/tool layouts stay consistent
regardless of which one a host integrates with.

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
