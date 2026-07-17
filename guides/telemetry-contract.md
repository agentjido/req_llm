# V1 Telemetry Contract

This inventory defines the public telemetry surface ReqLLM preserves through
the V1 release line. It records the current runtime behavior; it does not rename,
remove, or reinterpret existing events.

Use `ReqLLM.Telemetry.stable_events/0` for long-lived integrations and
`ReqLLM.Telemetry.events/0` when diagnostic tooling needs every emitted event.

## Stability levels

- **Stable** means the event name, required top-level keys, value categories,
  meaning, and units will remain compatible throughout V1. Additive keys remain
  possible.
- **Stable compatibility** has the same guarantee, but exists primarily for
  established consumers. New consumers should prefer the indicated stable event.
- **Experimental** means ReqLLM will keep emitting the event in V1, but may add
  or refine its diagnostic detail. Existing names and keys will not be removed or
  silently repurposed in V1.

## Complete event inventory

| Event | Measurements | Metadata | Stability | OpenTelemetry bridge |
|---|---|---|---|---|
| `[:req_llm, :request, :start]` | `system_time` (integer, native system time) | Request base | Stable | Starts one GenAI client span. |
| `[:req_llm, :request, :stop]` | `duration` (integer, native monotonic units), `system_time` (integer, native system time) | Request base; terminal values; optional stream and builtin-tool timing | Stable | Completes the span, applies terminal attributes/status, and records stop metrics. |
| `[:req_llm, :request, :exception]` | `duration` (integer, native monotonic units), `system_time` (integer, native system time) | Request base plus `error`; `finish_reason` is `:error` | Stable | Records error attributes and exception event, completes the span, and records failure duration. |
| `[:req_llm, :token_usage]` | `tokens` (map), `cost` (number or `nil`); optional numeric `input_cost`, `output_cost`, `reasoning_cost`, `total_cost` | Usage correlation | Stable compatibility | Not consumed directly. Usage on `request.stop` is mapped instead. |
| `[:req_llm, :request, :retry]` | `duration` (integer, native monotonic units), `system_time` (integer, native system time) | Request base plus `retry` | Experimental | Not consumed. One logical request still produces one span. |
| `[:req_llm, :reasoning, :start]` | `system_time` (integer, native system time) | Reasoning detail plus `milestone` | Experimental | Not consumed directly; normalized reasoning on request lifecycle events is mapped. |
| `[:req_llm, :reasoning, :update]` | `system_time` (integer, native system time) | Reasoning detail plus `milestone` | Experimental | Not consumed directly. |
| `[:req_llm, :reasoning, :stop]` | `duration` (integer, native monotonic units), `system_time` (integer, native system time) | Reasoning detail plus `milestone` | Experimental | Not consumed directly. |
| `[:req_llm, :tool_call_args_lost]` | `count` (integer count; currently `1`) | `tool_name`, `tool_call_id`, `reason` | Experimental | Not consumed. Raw argument fragments are not included. |

All elapsed native values use the VM's `:native` time unit. Convert them with
`System.convert_time_unit/3`. Retry `delay` and request timeout options are in
milliseconds. OpenTelemetry converts elapsed measurements to seconds without
changing the native events.

## Stable request metadata

The request base is present on request start, retry, stop, and exception:

| Key | Value category and meaning |
|---|---|
| `request_id` | String correlation identifier shared by the logical request's lifecycle, reasoning, and usage events. |
| `operation` | Atom such as `:chat`, `:object`, `:embedding`, `:rerank`, `:image`, `:speech`, or `:transcription`. |
| `mode` | `:sync` or `:stream`. |
| `provider` | Provider atom. |
| `model` | `%LLMDB.Model{}` selected for the request. |
| `transport` | `:req` or `:finch`. |
| `reasoning` | Fixed provider-neutral reasoning snapshot described below. |
| `request_options` | Compact normalized option map; absent values are omitted. |
| `server` | Resolved `address`, `port`, and `path` map, or an empty map. Credentials and query values are not included. |
| `request_started_system_time` | Integer native system timestamp, or `nil` before a start can be observed. |
| `request_summary` | Operation-specific counts and byte sizes. |
| `response_summary` | Operation-specific counts and byte sizes. |
| `http_status` | Integer HTTP status or `nil`. |
| `finish_reason` | Atom or `nil`; terminal values include `:stop`, `:length`, `:tool_calls`, `:content_filter`, `:cancelled`, `:incomplete`, `:error`, and `:unknown`. |
| `usage` | Normalized usage map or `nil`. |

The base keys remain present even when their value is `nil`. Additive metadata
does not change the meaning of these keys.

### Conditional request metadata

| Key | Presence and shape | Stability |
|---|---|---|
| `streaming` | Stream requests only. Always contains `first_chunk_at` and `time_to_first_chunk`, each integer native monotonic units or `nil`. | Stable |
| `request_payload` | Payload mode `:raw` only; sanitized request data. | Stable opt-in container; operation detail may grow. |
| `response_payload` | Payload mode `:raw` only; sanitized response data. | Stable opt-in container; operation detail may grow. |
| `error` | Exception events only; the existing exception or error term. | Stable |
| `retry` | Retry events only; `attempt`, `next_attempt`, `max_retries`, `delay` in milliseconds, and optional `http_status`. | Experimental |
| `builtin_tool_timing` | Terminal events only when timings exist; call-id keys with native Unix nanosecond start/end values. | Experimental |

`streaming.first_chunk_at` is recorded for the first non-empty content output or
tool call. Thinking-only and empty chunks do not start the timer. A stream stop,
cancellation, or failure continues to use the regular request terminal event.

### Nested stable shapes

`reasoning` always contains `supported?`, `requested?`, `effective?`,
`requested_mode`, `requested_effort`, `requested_budget_tokens`,
`effective_mode`, `effective_effort`, `effective_budget_tokens`,
`returned_content?`, `reasoning_tokens`, `content_bytes`, and `channel`. Values
are booleans, atoms, non-negative integers, or `nil`; `channel` is `:none`,
`:usage_only`, `:content_only`, or `:content_and_usage`.

`request_options` may contain `temperature`, `top_p`, `top_k`, `max_tokens`,
`frequency_penalty`, `presence_penalty`, `stop_sequences`, `seed`, `n`,
`stream?`, `encoding_formats`, `conversation_id`, `service_tier`,
`receive_timeout`, `total_timeout`, `stream_idle_timeout`, and `max_retries`.
Inference values retain their normalized scalar/list shape; timeout and retry
values are milliseconds/counts or `:infinity` where supported.

Request and response summaries intentionally vary by operation. They contain
counts, byte sizes, dimensions, formats, durations, and booleans, never raw
binary media or embedding vectors. New summary counters may be added in V1.

## Usage correlation metadata

The token usage event always includes `model`. When available it also includes
`request_id`, `operation`, `mode`, `provider`, and `transport`; direct low-level
emitters historically may omit unavailable correlation values. The `tokens` map
is the existing normalized usage shape and can add provider-neutral counters.

New billing integrations should read `usage` from `request.stop`, which combines
usage with terminal outcome and timing. The token usage event remains supported
for existing handlers.

## Redaction contract

Payload capture defaults to `:none`. In that mode request events contain
summaries, normalized options, server location, and usage, but no
`request_payload` or `response_payload` keys.

With `telemetry: [payloads: :raw]`, payload containers are opt-in but still
sanitized:

- reasoning and thinking text is replaced by byte counts and a redaction marker;
- tool callbacks and compiled schemas are removed;
- binary images, files, and audio are represented by size and media metadata;
- embeddings are represented by vector count and dimensions;
- malformed tool argument diagnostics include identifiers and a reason, never the
  raw fragment.

Reasoning lifecycle events never contain raw reasoning text in either payload
mode. Applications remain responsible for treating opt-in prompt, response, and
tool argument text as sensitive user data.

## Existing operational coverage

No extra V1 event is needed for the roadmap's identified cases:

- planning warnings remain on the request-plan/output diagnostic surfaces;
- terminal outcomes use `finish_reason` and exception `error`;
- configured total and idle budgets are present in `request_options`, while
  timeout failures preserve their typed error in exception metadata;
- shared stream materialization exposes its result through the response/output
  contracts and completes through the same request terminal event.

Adding parallel events for these cases would create competing sources of truth.
If a future requirement cannot be represented without changing an existing
meaning or unit, V1 will add a new namespaced or unit-bearing key/event and retain
the legacy field.

## OpenTelemetry compatibility

`ReqLLM.OpenTelemetry.events/0` remains the request start, stop, and exception
subset. Attaching the same handler id twice is collision-safe: `:telemetry`
returns `{:error, :already_exists}` and only one handler remains installed.

The bridge continues to map:

- request start to span identity, provider, operation, request model, normalized
  request options, output type, conversation id, and server attributes;
- request stop to finish reasons, response identity/model, usage/cost, optional
  content, builtin-tool child spans, duration, token, and streaming histograms;
- request exception to error status/type, exception detail, and failure duration.

Native `duration` and time-to-first-output values remain in native units; mapped
span attributes and histograms remain seconds. Content capture remains `:none` by
default, and OpenTelemetry attachment does not enable native raw payload capture.
The full attribute list and content modes are documented in the
[Telemetry guide](telemetry.md#opentelemetry-bridge).
