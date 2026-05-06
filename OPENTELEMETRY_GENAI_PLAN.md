# OpenTelemetry GenAI Semantic Conventions — Full Support Plan

Goal: bring ReqLLM into full conformance with the OpenTelemetry GenAI semantic
conventions so traces emitted by `ReqLLM.OpenTelemetry` and the dependency-free
mapper `ReqLLM.Telemetry.OpenTelemetry` work cleanly with native-OTel backends
such as Langfuse without bespoke instrumentation glue.

Each phase is independently shippable. Every checkbox lists both the work item
and how to verify it. "Verify" steps are concrete asserts you can encode as
ExUnit tests or as a manual smoke check.

---

## Phase 1 — Span attribute completeness

Adds the request, server, and reasoning attributes that LangFuse and other GenAI
backends already understand. No new dependencies.

### Work

- [x] Extract `ReqLLM.OpenTelemetry.SemConv` with shared helpers
      (`provider_name/1`, `operation_name/1`, `output_type/1`, `span_name/2`)
      and call it from both `ReqLLM.OpenTelemetry` and
      `ReqLLM.Telemetry.OpenTelemetry`.
- [x] Expand the provider-name map to add `azure → azure.ai.openai`,
      `groq → groq`, `xai → x_ai`, `deepseek → deepseek`. Keep
      `Atom.to_string/1` fallback for non-spec providers.
- [x] Capture per-request parameters in `ReqLLM.Telemetry.new_context/3` and
      surface them via `request_metadata/2` under a new `request_options` map:
      `temperature`, `top_p`, `top_k`, `max_tokens`, `frequency_penalty`,
      `presence_penalty`, `stop_sequences`, `seed`, `n`, `stream?`,
      `encoding_formats`, `conversation_id`.
- [x] Resolve `server.address` / `server.port` from the underlying
      `Req.Request.url` and stash them in lifecycle metadata.
- [x] Emit the corresponding `gen_ai.request.*` and `server.*` attributes from
      both OTel modules.
- [x] Emit `gen_ai.conversation.id` when the caller provided one.
- [x] Emit `gen_ai.usage.reasoning.output_tokens` from `usage.reasoning_tokens`.
- [x] Emit `gen_ai.embeddings.dimension.count` for embedding responses.
- [x] On `:stop` events with `http_status >= 400`, also set `error.type` on the
      span — currently only set on the `:exception` handler.

### How to verify

- [x] `test/req_llm/open_telemetry_test.exs` asserts every new attribute
      appears with the right value via a fake `Adapter` that captures
      `start_span`/`set_attributes` calls.
- [x] `test/req_llm/telemetry_open_telemetry_test.exs` asserts the same
      attributes on the dependency-free stub map.
- [x] New `test/req_llm/open_telemetry/sem_conv_test.exs` cross-checks that
      `ReqLLM.OpenTelemetry` and `ReqLLM.Telemetry.OpenTelemetry` produce
      identical `gen_ai.provider.name`, `gen_ai.operation.name`, and
      span names for the same metadata input. Today these diverge — the
      mapper just `Atom.to_string`s the provider while the bridge maps via
      `@provider_names`.
- [ ] Manual: run `examples/scripts/usage_cost_search_image.exs` with a
      console exporter attached and confirm the spans show
      `gen_ai.request.temperature`, `gen_ai.request.max_tokens`,
      `server.address` for at least Anthropic, OpenAI, and Google requests.
- [ ] Static: `mix quality` clean, dialyzer clean.

---

## Phase 2 — Content & instructions

Adds spec-shaped content payloads. Existing redaction guarantees are preserved.

### Work

- [x] Split system messages out of `gen_ai.input.messages` into a separate
      `gen_ai.system_instructions` attribute (text-only parts).
- [x] Emit `gen_ai.tool.definitions` from sanitized `request_payload.tools`
      (already stable-keyed: `name`, `description`, `strict`,
      `parameter_schema`).
- [x] Add `:include_content` (default `false`) to
      `ReqLLM.OpenTelemetry.attach/2` so the auto-bridge can promote
      structured messages, system instructions, and tool definitions when
      the host opts in.
- [x] Add `content: :event` mode to `ReqLLM.Telemetry.OpenTelemetry` that
      returns a `gen_ai.client.inference.operation.details` event stub
      instead of attaching the content as span attributes.

### How to verify

- [x] Tests assert that with a `Context` containing system + user + assistant
      + tool-call + tool-result messages, the request stub contains:
      - `gen_ai.system_instructions` only with the system content,
      - `gen_ai.input.messages` without the system message,
      - `gen_ai.tool.definitions` matching `Context.tools`.
- [x] Tests confirm `:include_content` defaults to off (back-compat) and that
      reasoning text never appears in any content attribute even when content
      capture is on.
- [x] Tests confirm `content: :event` returns a single
      `gen_ai.client.inference.operation.details` event with the same
      structured payload, and that `attributes` no longer contain
      `gen_ai.input.messages`.
- [ ] Manual: run a tool-using prompt and verify Langfuse renders the tool
      call and tool result as separate parts on the generation.

---

## Phase 3 — Metrics & streaming timings

Adds the four spec metrics and a span attribute for time-to-first-chunk.

### Work

- [x] Add an OTel metrics availability probe to
      `ReqLLM.OpenTelemetry.OTelAdapter` mirroring the tracer probe (check
      for `:otel_meter`, `:otel_meter_provider`, `:otel_histogram`).
- [x] Emit `gen_ai.client.operation.duration` (seconds histogram) on `:stop`
      and `:exception`.
- [x] Emit `gen_ai.client.token.usage` (token histogram) on `:stop`, once for
      `gen_ai.token.type=input` and once for `gen_ai.token.type=output`.
- [x] In `ReqLLM.Telemetry.observe_stream_chunk/2`, record the monotonic
      time of the first non-empty content chunk and stash it in the context.
- [x] Emit `gen_ai.client.operation.time_to_first_chunk` (seconds histogram)
      for streaming requests.
- [x] Emit `gen_ai.client.operation.time_per_output_chunk` (seconds histogram)
      computed as `(duration − time_to_first_chunk) / output_tokens` —
      reflects the per-token rate after the first chunk arrives.
- [x] Add `gen_ai.response.time_to_first_chunk` span attribute on streaming
      `:stop` events.

### How to verify

- [x] Test with a fake metrics adapter that captures histogram emissions.
      Assert that for sync requests only `operation.duration` and
      `token.usage` are recorded; for streaming requests
      `time_to_first_chunk` and `time_per_output_chunk` are recorded too.
- [x] Assert error path records `operation.duration` with `error.type`
      attribute set.
- [x] Assert metric attributes include `gen_ai.operation.name`,
      `gen_ai.provider.name`, `gen_ai.request.model`,
      `gen_ai.response.model`, `server.address`, `server.port` per spec.
- [ ] Manual: enable a Prometheus exporter and confirm histograms exist
      with the spec bucket boundaries (1, 4, 16, … for tokens; 0.01, 0.02,
      0.04, … for durations).

---

## Phase 4 — Cost, provider extensions, docs

Polish + Langfuse-friendly additions.

### Work

- [x] Emit `gen_ai.usage.cost` numeric attribute when ReqLLM has computed a
      USD cost.
- [x] Optional `langfuse.observation.cost_details` (JSON-encoded breakdown)
      gated behind a `langfuse: true` opt on `attach/2`.
- [x] OpenAI provider: emit `openai.api.type` (`chat_completions` |
      `responses`), `openai.request.service_tier`,
      `openai.response.service_tier`, `openai.response.system_fingerprint`.
      Path-based detection from the captured `server.path`; covers
      `:openai`, `:openai_codex`, and `:azure`.
- [x] Update `guides/telemetry.md` with the new attributes / metrics /
      events and a table of provider/operation enum mappings.
- [x] Add a "Sending traces to Langfuse" subsection: OTLP HTTP endpoints
      (EU/US/JP/HIPAA), basic-auth header format, recommendation to use
      `BaggageSpanProcessor` for `langfuse.user.id` / `langfuse.session.id`,
      note that gRPC is not supported by Langfuse today.
- [x] CHANGELOG entries per phase.
- [ ] Smoke test against a real Langfuse cloud project: confirm a generation
      shows model, cost, input/output tokens, conversation id, and
      structured input/output messages with tool calls visible.
      *(Manual — needs Langfuse credentials.)*

### How to verify

- [x] Test asserts `gen_ai.usage.cost` is emitted only when
      `usage.total_cost` is present and non-nil.
- [x] Test asserts `openai.{api.type,request.service_tier,response.service_tier,
      response.system_fingerprint}` attributes from synthetic metadata; OpenAI
      fixture-replay coverage can come later.
- [ ] `mix docs` renders the new telemetry guide section without warnings.
- [ ] Manual Langfuse smoke test passes (recorded screenshot in PR).

---

## Cross-cutting decisions to lock in

- [x] **Non-spec providers** (`alibaba`, `cerebras`, `meta`, `openrouter`,
      `vllm`, `zai`, `zenmux`, `venice`, `minimax`): keep
      `Atom.to_string/1` fallback. Implemented in
      `ReqLLM.OpenTelemetry.SemConv.provider_name/1` (default branch on
      `Map.get/3`) and documented in the "Provider name mapping" table of
      `guides/telemetry.md`.
- [x] **Non-spec operations** (`speech`, `transcription`, `rerank`):
      keep stringified atom names today. Implemented in
      `ReqLLM.OpenTelemetry.SemConv.operation_name/1` and documented in the
      "Operation name mapping" table of `guides/telemetry.md` (with the
      footnote: "Revisit if the spec adds enum values for them later").
- [x] **Back-compat:** every change is additive; existing
      `[:req_llm, :request, *]` consumers keep working. New metadata fields
      (`request_options`, `server`, `streaming`) are optional map keys.
      Existing keys (`request_id`, `operation`, `mode`, `provider`, `model`,
      `transport`, `reasoning`, `request_summary`, `response_summary`,
      `http_status`, `finish_reason`, `usage`, `request_payload`,
      `response_payload`) are unchanged. Public function signatures on
      `ReqLLM.Telemetry`, `ReqLLM.OpenTelemetry`, and
      `ReqLLM.Telemetry.OpenTelemetry` are unchanged. The only behaviour
      delta is that `error.type` is now also set on `:stop` spans for
      `http_status >= 400` (previously only on `:exception`).
- [ ] After every phase: `mix format`, `mix credo --strict`, `mix dialyzer`,
      `mix test` clean. *(Recurring gate — re-run before merge.)*

---

## References

OpenTelemetry GenAI semantic conventions (v1.37+):

- Overview: <https://opentelemetry.io/docs/specs/semconv/gen-ai/>
- Client spans: <https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/>
- Metrics: <https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/>
- Events / log records: <https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-events/>
- OpenAI extensions: <https://opentelemetry.io/docs/specs/semconv/gen-ai/openai/>
- Anthropic extensions: <https://opentelemetry.io/docs/specs/semconv/gen-ai/anthropic/>

Langfuse:

- Native OpenTelemetry integration: <https://langfuse.com/integrations/native/opentelemetry>

ReqLLM source touchpoints:

- `lib/req_llm/open_telemetry.ex` — auto-attached bridge with adapter behaviour
- `lib/req_llm/telemetry/open_telemetry.ex` — dependency-free span-stub mapper
- `lib/req_llm/telemetry.ex` — request-lifecycle context, summaries, payload
  sanitization, reasoning normalization
- `guides/telemetry.md` — user-facing docs for telemetry events and bridge
