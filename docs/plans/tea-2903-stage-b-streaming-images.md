# TEA-2903 Stage B: streaming image generation with partial frames (OpenAI + Azure)

## Context

Stage A (merged) made the full gpt-image parameter set available on the non-streaming path: `background`, `moderation`, `output_compression`, `input_fidelity`, the gpt-image `quality` tiers, and the `response_format` hoisting fix. Stage B adds the second half of the ticket: `stream: true` + `partial_images: N` on `POST /images/generations`, so a chat turn can show preview frames while the final picture renders (~7 s and ~10.7 s previews before a ~16 s final on gpt-image-1.5, verified on the Azure dev deployment with api-version `2025-04-01-preview`).

### Wire format (OpenAI; Azure mirrors it)

Each SSE `data:` line is a JSON object:

```json
{"type":"image_generation.partial_image","b64_json":"...","partial_image_index":0,
 "created_at":1700000000,"size":"1024x1024","quality":"medium","background":"transparent","output_format":"png"}
```

```json
{"type":"image_generation.completed","b64_json":"...","created_at":1700000000,
 "size":"1024x1024","quality":"medium","background":"transparent","output_format":"png",
 "usage":{"total_tokens":..,"input_tokens":..,"output_tokens":..,
          "input_tokens_details":{"text_tokens":..,"image_tokens":..}}}
```

Partial frames arrive opaque even when `background` is transparent; only the final frame carries alpha. `image_generation.completed` is terminal; a `[DONE]` sentinel is not guaranteed.

### What already exists (verified on main after Stage A)

- `ReqLLM.Streaming.start_stream/4` (`lib/req_llm/streaming.ex`) is operation-agnostic. Telemetry reads `Keyword.get(opts, :operation, :chat)`. Its only callers are `ReqLLM.Generation.stream_text_response/3` and `stream_object`, both hardcoded to `:chat`.
- `ReqLLM.StreamChunk` type `:content_part` carries a full `%ReqLLM.Message.ContentPart{}` and is wired end to end: `ChunkAccumulator`, `Defaults.ResponseBuilder.materialize_content_parts/6`, `StreamServer` progress counting, and `EventProjector` (projects image parts as `:output_item` events on channel `:files`).
- Stream-only chunk precedent: `metadata: %{stream_only?: true}` is skipped by `lib/req_llm/provider/chunk_accumulator.ex:138` and `lib/req_llm/provider/defaults/response_builder.ex:456` (for `:thinking` chunks today).
- A `:meta` chunk with `terminal?: true` ends a stream (`StreamServer.terminal_chunk?/1`). `termination_event?/1` recognises `[DONE]`, `%{"done" => true}`, `message_stop`, `response.completed`, but not `image_generation.completed`.
- `ReqLLM.Providers.OpenAI.ImagesAPI.attach_stream/4` and `decode_stream_event/2` are stubs (`lib/req_llm/providers/openai/images_api.ex`). Same stubs exist for xAI and Minimax; they stay untouched.
- `ReqLLM.Providers.OpenAI.attach_stream/4` (`lib/req_llm/providers/openai.ex:727`) calls `ReqLLM.RequestPlan.build(model, operation, stream: true)`; `RequestPlan.validate_operation/1` (`lib/req_llm/request_plan.ex:103`) allows only `:chat`/`:object`, and surfaces resolve by wire protocol only. `decode_stream_event/2,3` (`openai.ex:921,927`) route on `responses_api?(model)`, not on operation.
- `ReqLLM.Providers.Azure.attach_stream/4` (`lib/req_llm/providers/azure.ex:803`) hardcodes `get_chat_endpoint_path/…`. `decode_stream_event/2,3` (`azure.ex:898,904`) delegate to the model-family formatter. Image URL builder `get_image_endpoint_path/4` and `validate_image_model/1`, `validate_image_output_format/1`, `extract_azure_credentials/2`, `maybe_add_model_for_foundry/3` exist and are reusable. `do_prepare_image_request/3` is the non-streaming reference to mirror.
- `ReqLLM.Provider.Options.process_stream!/5` merges `stream: true` and validates against `ReqLLM.Images.schema()` for `:image`. The schema has no `:stream` or `:partial_images` key yet; `lib/req_llm/images/openai_compatible.ex` enforces at compile time that every schema key is classified in `@wire_option_keys` or `@plumbing_option_keys`.
- `ReqLLM.Images.OpenAICompatible` already has `media_type_for_output_format/1` (public, from Stage A), `image_size_class/2`, `image_response_usage/2`, `echoed_option/2`, `provider_meta_key/1`, `image_edit?/1`, and the private `extract_image_prompt/1`.
- Streaming timeouts default to 30 s (`streaming.ex` `:stream_receive_timeout`, `finch_client.ex`), while non-streaming images default to `:image_receive_timeout` = 120 s. The first partial frame can exceed 30 s at medium/high quality.
- HTTP 4xx before SSE is already handled by `StreamServer` as `ReqLLM.Error.API.Request`; the lazy stream raises `ReqLLM.Error.API.Stream` and `to_response/1` returns `{:error, _}`.
- Fixture shape for streams: `{captured_at, model_spec, provider, request, response: {status, headers, body: null}, streaming: true, chunks: [{b64: <raw SSE bytes>}]}`, replayed by `test/support/vcr.ex` `replay_into_stream_server/2`.
- Scenario catalog `lib/req_llm/compatibility/scenario_catalog.ex` has `{"image_basic", "image", …}` at line 179; `test/req_llm/compatibility/scenario_catalog_test.exs` asserts the scenario count and the per-capability scenario map, and that every fixture-proof scenario's fixture exists.
- Sample image models (`config/test.exs`): `openai:gpt-image-1.5`, `azure:gpt-image-2`. Coverage macro: `test/support/provider_test/image_generation.ex` (Azure creds at the bottom, `AZURE_IMAGE_DEPLOYMENT` override).

## B1. Options

- `lib/req_llm/images.ex` schema: add
  - `stream: [type: :boolean, default: false, doc: "Stream partial frames and the final image as SSE (stream_image/3 sets this)"]`
  - `partial_images: [type: {:in, 0..3}, doc: "Preview frames to stream before the final image (0-3; gpt-image models via stream_image/3 only)"]` (nil = provider default)
- `lib/req_llm/images/openai_compatible.ex`: add both to `@wire_option_keys` (the compile-time guard demands it). In `build_generation_body/1` append `maybe_put_stream(opts[:stream], opts[:partial_images])`, which puts `"stream" => true` and `"partial_images" => n` (when integer) only when `stream == true`. Non-streaming callers and Azure's body path are unaffected.
- Add `validate_stream_options/1`: `{:error, ReqLLM.Error.Invalid.Parameter}` when `image_edit?(opts)` ("streaming image edits are not supported; use generate_image/3") or when `n` is set and not 1.
- Make `extract_image_prompt/1` public as `prompt_from_context/1`.

## B2. Public API and chunk contract

### `ReqLLM.Images.stream_image/3` (next to `generate_image/3`)

```elixir
@image_streaming_providers [:openai, :azure]

def stream_image(model_spec, prompt_or_messages, opts \\ []) do
  opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :image, opts)

  with {:ok, model} <- ReqLLM.model(model_spec),
       :ok <- validate_streaming_provider(model),
       :ok <- ReqLLM.Images.OpenAICompatible.validate_stream_options(opts),
       {:ok, provider_module} <- ReqLLM.provider(model.provider),
       {:ok, opts} <- ReqLLM.Provider.Options.normalize_namespaced_provider_options(provider_module, :image, model, opts),
       {:ok, context} <- ReqLLM.Context.normalize(prompt_or_messages, opts),
       {:ok, stream_response} <- ReqLLM.Streaming.start_stream(provider_module, model, context, stream_opts(opts)) do
    {:ok, stream_response}
  else
    {:error, {:http_streaming_failed, {:provider_build_failed, %{__exception__: true} = error}}} -> {:error, error}
    {:error, error} -> {:error, error}
  end
end
```

- `stream_opts/1`: `Keyword.put(:operation, :image) |> Keyword.put(:stream, true) |> Keyword.put_new(:receive_timeout, Application.get_env(:req_llm, :image_receive_timeout, 120_000))`. The timeout is load-bearing (see B6).
- `validate_streaming_provider/1`: provider must be in `@image_streaming_providers`, else `Invalid.Parameter` "image streaming is not supported for provider …". This is the clean error for xAI/Minimax/Google without touching them (their provider-level `attach_stream/4` would otherwise build a chat request).
- `lib/req_llm.ex`: `defdelegate stream_image(model_spec, prompt_or_messages, opts \\ []), to: Images` after `generate_image!/3`, with `@doc`/`@spec` describing the chunk contract and pointing at `StreamResponse.images/1`.

### Chunk contract on `stream_response.stream`

1. 0..N partial frames: `%StreamChunk{type: :content_part, content_part: %ContentPart{type: :image, data: <bytes>, media_type: "image/png", metadata: %{partial?: true, partial_image_index: i, size:, quality:, background:, output_format:}}, metadata: %{partial?: true, partial_image_index: i, stream_only?: true}}`
2. Exactly one final image: same shape with `partial?: false` in both metadata maps and no `stream_only?`.
3. Terminal `StreamChunk.meta(%{terminal?: true, finish_reason: :stop, usage: <same map as non-streaming>, provider_meta: %{"openai" | "azure" => completed_event_minus_b64}})`.

### `to_response/1` yields only the final image

Reuse the `stream_only?` precedent, minimal blast radius:

- `lib/req_llm/provider/chunk_accumulator.ex`: before the `:content_part` clause add
  `def push(%__MODULE__{} = acc, %StreamChunk{type: :content_part, metadata: %{stream_only?: true}}), do: acc`
- `lib/req_llm/provider/defaults/response_builder.ex` `materialize_content_parts(:buffered, …)`: add `%StreamChunk{type: :content_part, metadata: %{stream_only?: true}} -> []` before the generic `:content_part` clause.
- Rejected: a custom ResponseBuilder for `:image` (`for_model/1` has no operation; OpenAI and Azure share the Defaults builder) and a new chunk type (breaks the `chunk_type` typespec and every `type in [...]` guard downstream).
- EventProjector needs no change: partial and final frames already surface as `:output_item` events; the dedupe fingerprint includes `item.data`, so partials are not collapsed.

### `ReqLLM.StreamResponse.images/1` (`lib/req_llm/stream_response.ex`, after `tokens/1` at line 137)

```elixir
@spec images(t()) :: Enumerable.t()
def images(%__MODULE__{stream: stream}) do
  stream
  |> Stream.filter(&match?(%StreamChunk{type: :content_part, content_part: %ContentPart{type: t}} when t in [:image, :image_url], &1))
  |> Stream.map(& &1.content_part)
end
```

Doc: yields partial frames then the final image; consumes the stream like `tokens/1`.

## B3. Shared decoder: `ReqLLM.Images.OpenAICompatible.decode_stream_event/2`

```elixir
def decode_stream_event(%{data: %{"type" => "image_generation.partial_image", "b64_json" => b64} = data}, _model) when is_binary(b64) do
  index = data["partial_image_index"]
  part = stream_image_part(data, %{partial?: true, partial_image_index: index})
  [StreamChunk.content_part(part, %{partial?: true, partial_image_index: index, stream_only?: true})]
end

def decode_stream_event(%{data: %{"type" => "image_generation.completed", "b64_json" => b64} = data}, model) when is_binary(b64) do
  part = stream_image_part(data, %{partial?: false})
  size_class = image_size_class(echoed_option(data, "size"), echoed_option(data, "quality"))
  usage = image_response_usage(data, ReqLLM.Usage.Image.build_generated(1, size_class))
  meta = %{terminal?: true, finish_reason: :stop, usage: usage,
           provider_meta: %{provider_key(model) => Map.delete(data, "b64_json")}}
  [StreamChunk.content_part(part, %{partial?: false}), StreamChunk.meta(meta)]
end

def decode_stream_event(%{data: %{"type" => "error"} = data}, _model), do: [error_meta(data["message"] || data["code"] || "image stream error")]
def decode_stream_event(%{data: %{"error" => %{"message" => message}}}, _model), do: [error_meta(message)]
def decode_stream_event(_event, _model), do: []
```

- `stream_image_part/2`: `%ContentPart{type: :image, data: Base.decode64!(b64), media_type: media_type_for_output_format(data["output_format"]), metadata: flags merged with echoed size/quality/background/output_format when binary}`.
- `error_meta/1`: `StreamChunk.meta(%{terminal?: true, finish_reason: :error, error: message})` (same shape as `responses_api.ex` uses), which makes `to_response/1` return `{:error, _}`.
- `provider_key/1`: `Atom.to_string(model.provider)`, mirroring `provider_meta_key/1`.
- `image_model?/1`: true when `model.extra[:family] == "gpt-image"` or the id starts with `gpt-image`, `dall-e`, or `chatgpt-image`. Accept `%LLMDB.Model{}` or a string id.
- `termination_event?/1` in `StreamServer` stays untouched; the terminal meta ends the stream.

## B4. OpenAI routing

- `lib/req_llm/providers/openai.ex` `attach_stream/4` (line 727): branch on `opts[:operation] || :chat`. `:image` → `Options.process_stream!(__MODULE__, :image, model, context, opts)` then `ReqLLM.Providers.OpenAI.ImagesAPI.attach_stream/4`. Other operations → existing body moved to `attach_planned_stream/5`. Bypass `RequestPlan` for images rather than adding an `:openai_images` surface (that would touch `validate_operation`, `resolve_openai_surface`, `surface_name`, `validate_transport_surface`, and their tests). The only consumer of the omitted `:req_llm_request_plan` Finch private, `call_metadata.ex`, tolerates its absence.
- `decode_stream_event/3` (line 927): first branch `ReqLLM.Images.OpenAICompatible.image_model?(model)` → `{OpenAICompatible.decode_stream_event(event, model), state}`; existing ResponsesAPI/ChatAPI branches unchanged. `/2` already delegates to `/3`. Model-based routing so error events in an image stream reach the image decoder.
- `lib/req_llm/providers/openai/images_api.ex` `attach_stream/4`, mirroring `chat_api.ex` `attach_stream`:
  - `validate_stream_options/1`, `prompt_from_context/1`
  - credential via `ReqLLM.Providers.OpenAI.resolve_request_credential!/2` and `auth_header_list/1`
  - headers: `Content-Type: application/json`, `Accept: text/event-stream`, plus `ReqLLM.Provider.Utils.extract_custom_headers(opts[:req_http_options])`
  - base URL via `ReqLLM.Provider.Options.effective_base_url/3`
  - body: `build_generation_body(opts ++ [prompt:, model: model.provider_model_id || model.id, stream: true])`
  - `{:ok, Finch.build(:post, base_url <> path(), headers, Jason.encode!(body))}`; rescue to `ReqLLM.Error.API.Request`
  - `decode_stream_event/2` delegates to the shared decoder.
- Update the OpenAI moduledoc Images bullet "Streaming not supported".

## B5. Azure routing (`lib/req_llm/providers/azure.ex`)

- `attach_stream/4` (line 803): branch on operation; move the existing body to `attach_chat_stream/5`; add `attach_image_stream/4` mirroring `do_prepare_image_request/3`:
  1. `validate_image_model(effective_model_id(model))`, `OpenAICompatible.validate_options(opts)`, `OpenAICompatible.validate_stream_options(opts)`, `prompt_from_context(context)`
  2. `resolve_base_url(model_family, opts)`, `process_stream!(__MODULE__, :image, model, context, Keyword.put(opts, :base_url, resolved))`
  3. `validate_image_output_format(processed)`, `extract_azure_credentials(model, processed)`, `get_image_endpoint_path(:generation, deployment, api_version, base_url)` (Foundry still errors)
  4. headers: `build_auth_header(api_key, model_family, base_url)`, `content-type: application/json`, `accept: text/event-stream`, custom headers
  5. body: `build_generation_body(processed ++ [prompt:, model: model_id, stream: true]) |> Map.delete("model") |> maybe_add_model_for_foundry(deployment, base_url)`
  6. `Finch.build(:post, join_url(base_url, path), headers, Jason.encode!(body))`; keep the existing rescue wrapper.
- `decode_stream_event/3` (line 904): first branch `image_model?(effective_model_id(model))` → shared decoder. `init_stream_state/1` and `flush_stream_state/2` need no change.
- Default api-version `2025-04-01-preview` is the version verified for image SSE; document that traditional URLs need it or later.

## B6. Timeouts

- `stream_image/3` injects `receive_timeout` = image default (120 s) via `put_new`. It flows into `FinchClient.stream_options` (per-read timeout, i.e. the gap between frames) and `Streaming.start_stream`'s legacy `next_timeout`.
- With `:stream_idle_timeout` configured, `StreamServer.reset_stream_idle_timeout/2` resets on `:content_part` chunks, so each partial frame resets the timer; the first frame is the long pole. Document that users must set it above the inter-frame gap (~4-7 s observed).
- `pool_timeout` defaults to `receive_timeout` in `FinchClient.stream_options`; fine.

## B7. Tests

Unit (`async: true`, hand-written payloads, tiny PNG bytes like `@png_bytes` in `test/provider/azure/image_test.exs` base64-encoded):

- New `test/req_llm/images/openai_compatible_stream_test.exs`: `decode_stream_event/2` for partial (chunk type, `stream_only?`, decoded bytes, index, echoed metadata, media type from `"output_format" => "jpeg"`), completed (two chunks; terminal meta with `finish_reason: :stop`, `usage.image_usage.generated == %{count: 1, size_class: "1024x1024:medium"}`, token fields), `{"type":"error"}` → terminal error meta, unknown → `[]`; `image_model?/1` truth table; `build_generation_body/1` emits `"stream"`/`"partial_images"` only when streaming; `validate_stream_options/1` rejects edits and `n: 2`.
- `test/providers/openai_images_test.exs`: `ImagesAPI.attach_stream/4` builds `POST …/images/generations` with `Accept: text/event-stream`, body `"stream" => true`, `"partial_images" => 2`, no `response_format` for gpt-image; `source_image` → `Invalid.Parameter`; `OpenAI.attach_stream(model, ctx, [operation: :image, api_key: …, partial_images: 2], :finch)` routes to ImagesAPI; `OpenAI.decode_stream_event(image_event, gpt_image_model)` routes to the image decoder.
- `test/provider/azure/image_test.exs` (or the `attach_stream/4` describe in `test/provider/azure/azure_test.exs`): traditional URL `/deployments/my-image-deploy/images/generations?api-version=2025-04-01-preview`, v1 GA `/images/generations`, Foundry error, `api-key` + `accept` headers, body without `"model"` and with `"stream" => true`; `output_format: :webp` → error; `Azure.decode_stream_event(partial_event, azure_model)` routes to the image decoder.
- Chunk accumulator test: `push/2` skips `:content_part` with `stream_only?: true`; response builder buffered profile agrees.
- `test/req_llm/stream_response_test.exs` (helpers `create_stream_response/1`, `create_metadata_handle/1`): stream of 2 partials + final + terminal meta → `images/1` yields 3 parts; `to_response/1` → `Response.images/1` has exactly one part with `partial?: false`, usage passthrough, `finish_reason == :stop`; a stream ending in an error meta → `{:error, _}`.
- `test/req_llm/images_test.exs`: `stream_image/3` returns `Invalid.Parameter` for xai/google models, for `source_image`, and for `n: 2`.

Coverage (fixture replay):

- `lib/req_llm/compatibility/scenario_catalog.ex` after `image_basic` (line 179): `{"image_streaming", "image", output_modalities: [:image], requirements: [:image_generation], transports: [:server_sent_events], applicability: :focused, providers: [:openai, :azure]}` plus routes to `test/coverage/openai/image_generation_test.exs` and `test/coverage/azure/image_generation_test.exs`. Update `test/req_llm/compatibility/scenario_catalog_test.exs` (scenario count, `"image" => ~w(image_basic image_streaming)`).
- `test/support/provider_test/image_generation.ex`: for providers in `[:openai, :azure]`, a test tagged `CompatibilityScenario.tag!(:image_streaming)` calling `ReqLLM.stream_image` with `partial_images: 2, quality: "low", size: "1024x1024"` (keeps fixtures small; `image_basic.json` is ~360 KB for one medium frame), asserting ≥ 1 partial, exactly one final, terminal meta, `usage.image_usage`, and one image after `to_response/1`.
- Recording: `LIVE=true mix test test/coverage/openai/image_generation_test.exs --only scenario:image_streaming`, and the Azure equivalent with `AZURE_OPENAI_API_KEY` / `AZURE_OPENAI_BASE_URL` / `AZURE_IMAGE_DEPLOYMENT`. Fixtures land at `test/support/fixtures/openai/gpt_image_1_5/image_streaming.json` and `test/support/fixtures/azure/gpt_image_2/image_streaming.json`. Then refresh `priv/model_compat_scenarios.json` via `mix mc "openai:gpt-image-1.5"` and `mix mc "azure:gpt-image-2"`.
- Note: as of Stage A the OpenAI account used locally had no credits (HTTP 429), and no Azure credentials were present in the environment. Recording needs both.

## B8. Docs

- `guides/image-generation.md`: drop "Streaming image generation/editing" from Current Limitations; add a "Streaming" section under OpenAI showing `ReqLLM.stream_image/3`, `StreamResponse.images/1`, `partial_images: 2`, the `partial?` metadata, `to_response/1`, the 120 s timeout, and that partial frames are opaque even with `background: :transparent`. Azure subsection: api-version `2025-04-01-preview` or later, traditional and v1 GA URLs, Foundry unsupported.
- Moduledocs: `ReqLLM.Images`, `ReqLLM.Providers.OpenAI` (Images bullet), `ReqLLM.Providers.OpenAI.ImagesAPI`, `ReqLLM.Images.OpenAICompatible` (SSE events under "Wire format"), `ReqLLM.StreamResponse.images/1`, `ReqLLM.StreamChunk.content_part/2` (`stream_only?`/`partial?`).
- Do not touch `CHANGELOG.md`.

## B9. Risks to check while implementing

- Confirm `ReqLLM.Usage.Normalize.normalize/1` preserves `:image_usage` on the streaming usage path (`StreamServer` merges meta usage through `Usage.normalize` + `Cost.apply`; `Billing` reads `image_usage` via `ReqLLM.Usage.Image.count_generated`). Confirm `ReqLLM.Telemetry` accepts `operation: :image` in stream mode (`summarize_request/2` already lists `:image`).
- Memory: each frame is a decoded binary queued in `StreamServer` until consumed; `Enum.to_list` on a `partial_images: 3` high-quality stream holds four 1-3 MB binaries. The accumulator skip keeps partials out of the built Response.
- The "streaming: support in-process providers" commit (#1040) added an `:in_process` transport to `ReqLLM.Streaming`. Verified after merge: `start_stream/4` keeps its signature, and the transport is chosen by an optional provider `stream_transport/2` callback (`streaming.ex:305`), so OpenAI and Azure stay on the HTTP path. No change needed for `stream_image/3`.
- `n > 1` is rejected up front; lifting it later needs `Usage.merge` semantics for `image_usage.generated.count` checked first.
- The `ReqLLM.Providers.OpenAI.API` behaviour is unchanged; xAI/Minimax `ImagesAPI` stubs stay unreachable thanks to the provider gate in `stream_image/3`.
- RequestPlan bypass omits `:req_llm_request_plan` on image Finch requests; only `call_metadata.ex` reads it and tolerates absence.

## Verification

1. `mix compile --warnings-as-errors` (the compile-time guard must accept `:stream`/`:partial_images` as wire keys).
2. Unit tests above, then full `mix test` and `mix quality`. Pre-existing environment failures (missing Cohere/Azure MAI keys, OpenAI files upload hitting the live API) are unrelated.
3. Record `image_streaming` fixtures for `openai:gpt-image-1.5` and `azure:gpt-image-2`; re-run `mix test --only scenario:image_streaming` in replay mode; `mix mc` for both models.
4. Manual: `{:ok, s} = ReqLLM.stream_image("azure:gpt-image-1.5", prompt, base_url: …, deployment: …, partial_images: 2, background: :transparent)`; `s |> ReqLLM.StreamResponse.images() |> Enum.map(& &1.metadata)` shows two partials then the final; `ReqLLM.StreamResponse.to_response(s)` has one image whose PNG header reports color type 6 (RGBA) and `usage.image_usage`.
