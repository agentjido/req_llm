# Telemetry

ReqLLM emits native `:telemetry` events for every request, sync or streaming, and ships an OpenTelemetry bridge that turns those events into GenAI client spans following the [OpenTelemetry GenAI semantic conventions][otel-gen-ai]. Use the native events for billing, tenant attribution, and tight integrations; use the OTel bridge to feed Langfuse, Honeycomb, Grafana, or any other GenAI-aware backend.

Every event for a logical request shares the same `request_id`, so request lifecycle, reasoning lifecycle, and token usage correlate without provider-specific parsing.

## Contents

- [Quickstart](#quickstart)
- [Native telemetry events](#native-telemetry-events)
  - [V1 stability contract](#v1-stability-contract)
  - [Event families](#event-families)
  - [Measurements](#measurements)
  - [Request metadata](#request-metadata)
  - [Standardized reasoning metadata](#standardized-reasoning-metadata)
  - [Reasoning milestones](#reasoning-milestones)
  - [Token usage compatibility event](#token-usage-compatibility-event)
  - [Attaching telemetry handlers](#attaching-telemetry-handlers)
  - [Payload capture](#payload-capture)
- [OpenTelemetry bridge](#opentelemetry-bridge)
  - [Span attributes](#span-attributes)
  - [Metrics](#metrics)
  - [Content capture (opt-in)](#content-capture-opt-in)
  - [Cost capture](#cost-capture)
  - [OpenAI provider extensions](#openai-provider-extensions)
  - [Stale in-flight spans](#stale-in-flight-spans)
  - [Provider and operation name mapping](#provider-and-operation-name-mapping)
- [Langfuse](#langfuse)
- [Caller-context attributes](#caller-context-attributes)
- [Custom adapter](#custom-adapter)
- [Dependency-free mapper](#dependency-free-mapper)
- [Coverage across APIs](#coverage-across-apis)
- [See also](#see-also)

## Quickstart

**Native `:telemetry` only** — attach a handler and you'll see every request:

```elixir
:telemetry.attach_many("my-app", [
  [:req_llm, :request, :start],
  [:req_llm, :request, :stop],
  [:req_llm, :request, :exception]
], &MyApp.handle_event/4, nil)
```

**OpenTelemetry spans** — one call at startup, every ReqLLM request becomes a GenAI client span:

```elixir
case ReqLLM.OpenTelemetry.attach() do
  :ok -> :ok
  {:error, :opentelemetry_unavailable} -> :ok
end
```

You still need OpenTelemetry SDK + exporter wired up in your host app — ReqLLM does not configure exporters for you.

**Langfuse** — add cost details and message capture:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel",
  content: :attributes,
  langfuse: true
)

ReqLLM.generate_text(model, prompt,
  telemetry: [payloads: :raw, conversation_id: "thread-42"]
)
```

See [Langfuse](#langfuse) for the OTLP endpoint and auth setup.

---

## Native telemetry events

### V1 stability contract

For long-lived integrations, attach to `ReqLLM.Telemetry.stable_events/0`. It
contains request start, stop, and exception plus the backwards-compatible token
usage event. Streaming first-output timing is part of request lifecycle metadata,
so streaming does not require a separate event subscription.

`ReqLLM.Telemetry.events/0` returns the complete V1 inventory, including
diagnostic events whose detailed metadata remains experimental. See the
[V1 telemetry contract](telemetry-contract.md) for the exhaustive event, field,
unit, stability, redaction, and OpenTelemetry mapping inventory.

### Event families

| Event | When it fires |
|---|---|
| `[:req_llm, :request, :start]` | Request begins. |
| `[:req_llm, :request, :retry]` | A retryable provider attempt completes before its scheduled retry. |
| `[:req_llm, :request, :stop]` | Request completes (including streaming completion or cancellation). |
| `[:req_llm, :request, :exception]` | Request fails. |
| `[:req_llm, :reasoning, :start]` | Effective request enables provider reasoning. |
| `[:req_llm, :reasoning, :update]` | Reasoning milestone (not every chunk). |
| `[:req_llm, :reasoning, :stop]` | Reasoning request finishes, is cancelled, or errors. |
| `[:req_llm, :token_usage]` | Compatibility event for token and cost tracking. |
| `[:req_llm, :tool_call_args_lost]` | Diagnostic emitted when streamed tool arguments cannot be recovered. |

Request lifecycle events always include a `reasoning` map, even when the operation does not support reasoning — the snapshot is explicit about that case.

### Measurements

- `request.start`, `reasoning.start`, `reasoning.update` emit `%{system_time: integer}`.
- `request.retry`, `request.stop`, `request.exception`, `reasoning.stop` emit `%{duration: integer, system_time: integer}`.
- `tool_call_args_lost` emits `%{count: 1}`.

`duration` is in native monotonic time units — convert with `System.convert_time_unit/3` if you want milliseconds.
For `request.retry`, it is the completed provider attempt duration. Its `retry`
metadata contains `attempt`, `next_attempt`, `max_retries`, `delay` in
milliseconds, and `http_status` when present. No request or response body is
included.

### Request metadata

Every request lifecycle event includes these base keys:

- `request_id`, `operation`, `mode`, `provider`, `model`, `transport`
- `reasoning`, `request_summary`, `response_summary`
- `http_status`, `finish_reason`, `usage`
- `request_options`, `server`, `request_started_system_time`

Streaming requests additionally include `streaming`. When payload capture is
enabled, `request_payload` and `response_payload` are also included. Retry events
add `retry`, exception events add `error`, and terminal streaming events may add
`builtin_tool_timing` when server-side builtin tool timings are available.

`request_options` is a compact map of normalized inference parameters extracted from the original call: `temperature`, `top_p`, `top_k`, `max_tokens`, `frequency_penalty`, `presence_penalty`, `stop_sequences`, `seed`, `n` (choice count), `stream?`, `encoding_formats`, `conversation_id`, `service_tier`, `receive_timeout`, `total_timeout`, `stream_idle_timeout`, and `max_retries`. Nil values are dropped.

`server` is the resolved upstream endpoint (`address`, `port`, `path`). It is populated as soon as ReqLLM has a request URL and may be empty when the URL is unavailable.

`streaming` is set on streaming requests only and is absent from sync-request metadata. It exposes `first_chunk_at` (a `System.monotonic_time/0` reading) and `time_to_first_chunk` (in `:native` units, measured from request start to the first non-empty content chunk). Both values stay `nil` until ReqLLM observes the first content chunk via `ReqLLM.Telemetry.observe_stream_chunk/2`.

A typical metadata payload:

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

`request_summary` and `response_summary` shape varies by operation:

- Chat / object / image **requests** summarize message count, text bytes, image parts, tool calls.
- Chat / object / image **responses** summarize text bytes, thinking bytes, tool calls, image count, structured object presence.
- **Embeddings** summarize input count, vector count, dimensions.
- **Speech** summarizes input text bytes plus output audio size and format.
- **Transcription** summarizes input audio size plus transcript text bytes, segment count, duration.

### Standardized reasoning metadata

The `reasoning` map is the provider-neutral contract for thinking observability:

| Field | Meaning |
|---|---|
| `supported?` | Operation and model support reasoning. |
| `requested?` | Caller asked for reasoning in the original options. |
| `effective?` | Translated provider request still requests reasoning. |
| `requested_mode` / `_effort` / `_budget_tokens` | Caller intent. |
| `effective_mode` / `_effort` / `_budget_tokens` | What the provider request actually used. |
| `returned_content?` | Reasoning content was observed in the response. |
| `reasoning_tokens` | Normalized reasoning token usage when exposed by the provider. |
| `content_bytes` | Reasoning content size without exposing the content itself. |
| `channel` | `:none` &#124; `:usage_only` &#124; `:content_only` &#124; `:content_and_usage`. |

Requested reasoning is normalized from the original ReqLLM options (`reasoning_effort`, `thinking: %{type: "enabled", ...}`, `provider_options: [google_thinking_budget: ...]`, etc.). Effective reasoning is normalized from the translated provider request, so OpenAI, Anthropic, Google, Vertex, and others compare through the same shape.

Covered provider shapes:

- OpenAI-style effort fields (`reasoning.effort`, `reasoning_effort`) on OpenAI, OpenRouter, Groq, xAI
- Anthropic-style thinking fields on Anthropic, Azure Claude, Bedrock Claude, Vertex Claude
- Google-style thinking budgets on Google Gemini and Vertex Gemini
- Alibaba `enable_thinking` / `thinking_budget`
- Zenmux `reasoning.enable` / `depth` / `reasoning_effort`
- Z.AI `thinking.type`

`requested` and `effective` can diverge when provider translation drops, disables, or rewrites a reasoning configuration. When callers send conflicting controls, explicit disable signals (`thinking: %{type: "disabled"}`, `reasoning_effort: :none`, zero-token budgets) win over enable hints.

### Reasoning milestones

Reasoning events never include raw thinking text. They are metadata-only, even when payload capture is enabled.

`reasoning.start` uses `milestone: :request_started`.

`reasoning.update` is emitted only for transitions:

- `:content_started` — first reasoning content observed
- `:usage_updated` — reasoning token usage first appears or changes
- `:details_available` — provider reasoning details become available

`reasoning.stop` uses the terminal outcome: `:stop`, `:length`, `:tool_calls`, `:cancelled`, `:incomplete`, `:error`, `:unknown`.

### Token usage compatibility event

`[:req_llm, :token_usage]` remains available for existing consumers and fires for both streaming and non-streaming requests.

Measurements preserve the V1 nested shape:

- `tokens` — normalized token counters such as `input`, `output`, `total_tokens`,
  `reasoning`, `cached_input`, and `cache_creation` when available.
- `cost` — total USD cost or `nil`.
- `input_cost`, `output_cost`, `reasoning_cost`, `total_cost` — optional USD
  breakdown keys when model pricing is available.

Metadata: `model`, `request_id`, `operation`, `mode`, `provider`, `transport`.

**For new integrations, prefer `[:req_llm, :request, :stop]`** — it includes duration, finish reason, summaries, and normalized reasoning metadata alongside usage.

### Attaching telemetry handlers

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

### Payload capture

By default, telemetry is metadata-only:

```elixir
config :req_llm, telemetry: [payloads: :none]
```

Opt into payload capture globally:

```elixir
config :req_llm, telemetry: [payloads: :raw]
```

Or per request:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", telemetry: [payloads: :raw])
ReqLLM.stream_text("openai:gpt-5-mini", "Hello", telemetry: [payloads: :raw])
```

Payload mode only affects request lifecycle events. Reasoning events stay metadata-only.

The `telemetry:` option also accepts `:conversation_id`, which flows through to `request_options.conversation_id` and to `gen_ai.conversation.id` on the OpenTelemetry bridge:

```elixir
ReqLLM.generate_text(model, prompt, telemetry: [conversation_id: "thread-42"])
```

Raw payload mode is still sanitized:

- Reasoning and thinking text is redacted from payloads.
- Tools are emitted as stable metadata only (`name`, `description`, `strict`, `parameter_schema`).
- Binary message parts (images, files) are summarized by byte size, media type, and filename — never raw bytes.
- Unknown payload shapes are recursively sanitized so opaque binaries are summarized.
- Speech telemetry reports audio size and format, not raw audio bytes.
- Embedding telemetry reports vector counts and dimensions, not the vectors themselves.
- Transcription telemetry stays structured.

Use raw payload capture carefully in multi-tenant systems — payloads may still contain user content, tool call arguments, and structured outputs.

---

## OpenTelemetry bridge

`ReqLLM.OpenTelemetry` turns the normalized request lifecycle telemetry above into GenAI client spans.

Attach it once during application startup:

```elixir
case ReqLLM.OpenTelemetry.attach() do
  :ok -> :ok
  {:error, :opentelemetry_unavailable} -> :ok
end
```

ReqLLM does not configure an SDK or exporter for you. To export traces, your host application still needs normal OpenTelemetry setup (`:opentelemetry`, an exporter dep).

### Span attributes

**On span start:**

- `gen_ai.provider.name` (spec enum where defined; stringified atom otherwise)
- `gen_ai.operation.name` (`chat`, `embeddings`, `generate_content`, …)
- `gen_ai.request.model`
- `gen_ai.output.type` (`text`, `json`, `image`, `speech` — operation-dependent)
- `gen_ai.request.temperature`, `top_p`, `top_k`, `max_tokens`
- `gen_ai.request.frequency_penalty`, `presence_penalty`
- `gen_ai.request.stop_sequences`, `seed`
- `gen_ai.request.choice.count` (from `:n`)
- `gen_ai.request.stream` (`true` for `stream_text` / `stream_object`)
- `gen_ai.request.encoding_formats` (embeddings)
- `gen_ai.conversation.id` when the caller passes `telemetry: [conversation_id: …]`
- `server.address`, `server.port` resolved from the underlying `Req.Request.url`

**On span stop:**

- `gen_ai.response.finish_reasons`
- `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`
- `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_creation.input_tokens` when available
- `gen_ai.usage.reasoning.output_tokens` when reported
- `gen_ai.usage.cost` (USD) when ReqLLM has computed a cost breakdown
- `gen_ai.embeddings.dimension.count` for embedding responses
- `error.type` and span status `:error` when `http_status >= 400`

**On span exception:** `error.type` and an exception event.

**Streaming:** `gen_ai.response.time_to_first_chunk` (seconds) is set on the stop span, measured from request start to the first non-empty content chunk observed by `ReqLLM.Telemetry.observe_stream_chunk/2`.

[otel-gen-ai]: https://opentelemetry.io/docs/specs/semconv/gen-ai/

### Metrics

When the OpenTelemetry metrics API is available alongside the tracer, the bridge also records spec histograms. No extra configuration is needed beyond a working OTel meter provider:

| Metric | When | Notes |
|---|---|---|
| `gen_ai.client.operation.duration` (s) | stop + exception | sets `error.type` on failures |
| `gen_ai.client.token.usage` ({token}) | stop | one record per `gen_ai.token.type` |
| `gen_ai.client.operation.time_to_first_chunk` (s) | streaming | from first non-empty content chunk |
| `gen_ai.client.operation.time_per_output_chunk` (s) | streaming | `(duration − TTFC) / output_tokens` |

Each histogram is created lazily with the OpenTelemetry GenAI spec bucket boundaries — `[0.01, 0.02, 0.04, …, 81.92]` for durations and `[1, 4, 16, …, 67_108_864]` for token counts. Per-record attributes follow the spec: `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, `server.address`, `server.port`.

If the meter API is unavailable (you only depend on the tracer SDK), metrics emission is silently skipped while spans still record.

### Content capture (opt-in)

By default the bridge does **not** attach prompt or response content. Pass `:content` to promote structured messages, system instructions, and tool definitions, and enable raw payload capture on the calls you want to record:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", content: :attributes)

ReqLLM.generate_text(model, prompt, telemetry: [payloads: :raw])
```

Content modes:

- `:none` (default) — no message, instructions, or tool definitions.
- `:attributes` (alias: `true`) — sets `gen_ai.input.messages`, `gen_ai.system_instructions`, `gen_ai.tool.definitions`, `gen_ai.output.messages` as span attributes.
- `:event` — same payload, bundled into a single `gen_ai.client.inference.operation.details` span event on the terminal lifecycle event.

Captured fields:

- `gen_ai.system_instructions` — text-only parts from system messages
- `gen_ai.input.messages` — non-system input messages with tool calls and tool results expressed as part records
- `gen_ai.tool.definitions` — `[%{"type" => "function", "name" => …, …}, …]` derived from `Context.tools`
- `gen_ai.output.messages` — assistant response with `finish_reason`

Reasoning text never appears in any of these, even if the model returned thinking parts. ReqLLM's payload sanitizer redacts reasoning before the bridge sees the messages, and the content mapper additionally keeps only spec-friendly text, URI, media-descriptor, file-descriptor, tool-call, and tool-result parts.

### Cost capture

When ReqLLM has computed a USD cost breakdown, the bridge sets `gen_ai.usage.cost` (number, USD total) on the stop span. Cost lookup uses the same model pricing tables as `[:req_llm, :token_usage]`.

Pass `langfuse: true` to `attach/2` to additionally emit `langfuse.observation.cost_details` — a JSON string with the per-bucket breakdown (`input`, `output`, `reasoning`, `total`). The attribute is dropped silently when no cost data is available, so it's safe to leave on globally:

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", langfuse: true)
```

### OpenAI provider extensions

For OpenAI-family providers (`openai`, `openai_codex`, `azure`) the bridge emits the spec's [OpenAI extension attributes][otel-openai] when ReqLLM has the data:

- `openai.api.type` — `"chat_completions"`, `"responses"`, or `"embeddings"`, inferred from the request URL path
- `openai.request.service_tier` — when the caller passed `service_tier:` (or `provider_options: [service_tier: …]`)
- `openai.response.service_tier` — when the response body carried it
- `openai.response.system_fingerprint` — when the response body carried it

Capturing the response-side fields requires `telemetry: [payloads: :raw]` on the call so the bridge can read `provider_meta` from the parsed response.

[otel-openai]: https://opentelemetry.io/docs/specs/semconv/gen-ai/openai/

### Stale in-flight spans

The bridge tracks in-flight spans in a named ETS table keyed by handler id and request id. Each `:start` event inserts an entry; the matching `:stop`/`:exception` removes it. If a request never produces a terminal event (e.g. the calling process crashes mid-request before `:telemetry.span/3` emits), the entry stays until `ReqLLM.OpenTelemetry.detach/1` runs.

Long-running hosts can call `ReqLLM.OpenTelemetry.prune_stale_spans/2` periodically to drop entries older than a TTL. The simplest way is [`:telemetry_poller`][telemetry-poller]:

```elixir
children = [
  {:telemetry_poller,
   measurements: [
     {ReqLLM.OpenTelemetry, :prune_stale_spans, ["req-llm-otel", :timer.minutes(5)]}
   ],
   period: :timer.minutes(1)}
]
```

`prune_stale_spans/2` returns the number of entries it removed. The default handler id is `"req-llm-open-telemetry"` if you call `ReqLLM.OpenTelemetry.attach/0` without an explicit handler id.

[telemetry-poller]: https://hexdocs.pm/telemetry_poller/

### Provider and operation name mapping

| ReqLLM provider | `gen_ai.provider.name` |
|---|---|
| `:openai` | `openai` |
| `:anthropic` | `anthropic` |
| `:azure` | `azure.ai.openai` |
| `:google` | `gcp.gen_ai` |
| `:google_vertex` | `gcp.vertex_ai` |
| `:amazon_bedrock` | `aws.bedrock` |
| `:groq` | `groq` |
| `:xai` | `x_ai` |
| `:deepseek` | `deepseek` |

Other providers (`alibaba`, `cerebras`, `meta`, `openrouter`, `vllm`, `zai`, `zenmux`, `venice`, `minimax`, …) are stringified verbatim from their atom name.

| ReqLLM operation | `gen_ai.operation.name` | `gen_ai.output.type` |
|---|---|---|
| `:chat` | `chat` | `text` |
| `:object` | `chat` | `json` |
| `:embedding` | `embeddings` | _(not set)_ |
| `:image` | `generate_content` | `image` |
| `:speech` | `speech` * | `speech` |
| `:transcription` | `transcription` * | `text` |

\* Non-spec operations (`speech`, `transcription`, `rerank`) are stringified unchanged. Revisit if the spec adds enum values for them.

---

## Langfuse

[Langfuse][langfuse-otel] consumes ReqLLM's GenAI spans natively over OTLP HTTP. Point your existing OTel pipeline at one of Langfuse's endpoints:

| Region   | OTLP HTTP endpoint                                  |
|----------|-----------------------------------------------------|
| EU       | `https://cloud.langfuse.com/api/public/otel`        |
| US       | `https://us.cloud.langfuse.com/api/public/otel`     |
| Japan    | `https://jp.cloud.langfuse.com/api/public/otel`     |
| HIPAA US | `https://hipaa.cloud.langfuse.com/api/public/otel`  |

Langfuse only accepts OTLP/HTTP — gRPC is not supported.

Auth uses HTTP basic auth with your project keys, base64-encoded:

```elixir
auth = "Basic " <> Base.encode64("#{public_key}:#{secret_key}")

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_traces_endpoint: "https://us.cloud.langfuse.com/api/public/otel/v1/traces",
  otlp_traces_headers: [{"authorization", auth}]
```

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

Langfuse will show model, cost (with breakdown), input/output token counts, `gen_ai.conversation.id`, and structured input/output messages including tool calls. Add `langfuse.user.id`, `langfuse.session.id`, or tags yourself when you need caller attribution.

For per-trace user/session attribution (`langfuse.user.id`, `langfuse.session.id`, `langfuse.tags`, …), see [Caller-context attributes](#caller-context-attributes). ReqLLM itself does not set them — they are caller context.

[langfuse-otel]: https://langfuse.com/integrations/native/opentelemetry

---

## Caller-context attributes

`langfuse.user.id`, `langfuse.session.id`, and similar caller-context attributes are not set by ReqLLM. Three patterns:

### Option 1 — Wrap the call in a parent span (recommended)

Set attributes on a span you already control; ReqLLM's client span becomes a child, and Langfuse picks them up at the trace root:

```elixir
require OpenTelemetry.Tracer, as: Tracer

Tracer.with_span "chat.handle_message" do
  Tracer.set_attributes([
    {"langfuse.user.id", current_user.id},
    {"langfuse.session.id", session_id}
  ])

  ReqLLM.generate_text(model, prompt, telemetry: [conversation_id: session_id])
end
```

### Option 2 — Baggage with a copy-on-start span processor

For attributes that should flow across many call sites, set OTel baggage and register a span processor that copies it onto every span:

```elixir
OpenTelemetry.Baggage.set(%{"langfuse.user.id" => user.id})
ReqLLM.generate_text(model, prompt)
```

The Erlang OpenTelemetry SDK does **not** ship a `BaggageSpanProcessor` out of the box. Pull a community implementation from hex, or write a small `:otel_span_processor` that copies baggage onto every span at start. Register it in `config.exs` ahead of your batch processor.

### Option 3 — Custom adapter

Inject attributes only on ReqLLM client spans (e.g. from `Process.get/1` or a `Plug.Conn` assign) by wrapping `ReqLLM.OpenTelemetry.OTelAdapter` and passing your module via `:adapter`. See `ReqLLM.OpenTelemetry.Adapter` for the full behaviour and a worked example.

### Picking an option

| Use case | Option |
|---|---|
| Request handler with logged-in user | 1 |
| Cross-process fan-out, async jobs | 2 |
| Pattern you can't easily move into baggage | 3 |

---

## Custom adapter

The bridge talks to OpenTelemetry through `ReqLLM.OpenTelemetry.Adapter`, a thin behaviour. Implement it to swap in a different tracer, inject extra attributes, or run in test mode without an OTel SDK. See the `ReqLLM.OpenTelemetry.Adapter` moduledoc for the callback list and a delegating skeleton.

## Dependency-free mapper

For advanced integrations that want to drive a custom tracer directly, `ReqLLM.Telemetry.OpenTelemetry` builds span stubs from ReqLLM telemetry metadata without attaching handlers or depending on an OpenTelemetry SDK:

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

The mapper emits the same `gen_ai.*` and `server.*` attribute set as the auto-attach bridge — provider/operation/output type, request parameters, server, usage, finish reasons, reasoning tokens, embedding dimension count, HTTP error type — plus richer normalized response and content metadata:

- `gen_ai.response.id`, `gen_ai.response.model`
- `gen_ai.input.messages` (system messages move to `gen_ai.system_instructions`)
- `gen_ai.system_instructions`, `gen_ai.tool.definitions`
- `gen_ai.output.messages` with finish reasons
- tool call and tool result payloads in message parts
- exception event payloads for manual span finishing

Content modes mirror the bridge: `:none` (default), `:attributes`, `:event`.

Pass `langfuse: true` to also emit `langfuse.observation.cost_details` on the stop stub when ReqLLM has cost data.

Pass `measurements: %{duration: native}` to populate the `metrics` field on the returned stub. Records use the same shape and bucket boundaries as the auto-bridge:

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

Streaming requests also surface `gen_ai.response.time_to_first_chunk` in `stub.attributes` when ReqLLM observed a non-empty content chunk.

Both surfaces share the same internal name table and content shaper, so provider/operation/output values and message/tool layouts stay consistent regardless of which one a host integrates with.

---

## Coverage across APIs

These event families are emitted for:

- high-level sync APIs: `ReqLLM.generate_text/3`, `generate_object/4`, `generate_image/3`, `embed/3`, `transcribe/3`, `speak/3`
- high-level streaming APIs: `ReqLLM.stream_text/3`, `stream_object/4`
- low-level Req-backed flows: `provider_module.prepare_request/4` + `Req.request/1`
- low-level streaming flows: `ReqLLM.Streaming.start_stream/4`

If you need observability that covers both sync and streaming, attach to ReqLLM telemetry rather than Req middleware alone.

## See also

- [Usage & Billing](usage-and-billing.md)
- [Configuration](configuration.md)
- [Core Concepts](core-concepts.md)
