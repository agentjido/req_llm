# Fireworks AI

High-throughput inference for open-weight models (DeepSeek, GLM, Kimi, MiniMax, GPT-OSS, Qwen, and others) on Fireworks's hardware. OpenAI-compatible chat endpoint with Fireworks-specific extensions.

## Configuration

```bash
FIREWORKS_API_KEY=fw_...
```

Or programmatically:

```elixir
ReqLLM.put_key(:fireworks_ai_api_key, "fw_...")
```

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Fireworks model IDs are path-like — `accounts/fireworks/models/<slug>`. Use exact Fireworks IDs from [LLMDB.xyz](https://llmdb.xyz) when possible. If you need to use a model ID before it lands in the registry, use `ReqLLM.model!/1`:

```elixir
ReqLLM.generate_text(
  "fireworks_ai:accounts/fireworks/models/kimi-k2p5",
  "Hello!"
)

# Or inline for models not yet in LLMDB:
model = ReqLLM.model!(%{
  provider: :fireworks_ai,
  id: "accounts/fireworks/models/some-new-model"
})
ReqLLM.generate_text(model, "Hello!")
```

## Provider Options

Passed at the top level or nested under `:provider_options`.

### `min_p`
- **Type**: float
- **Purpose**: Minimum-probability sampling parameter
- **Example**: `min_p: 0.05`

### `repetition_penalty`
- **Type**: float
- **Purpose**: Repetition penalty applied during decoding
- **Example**: `repetition_penalty: 1.1`

### `typical_p`
- **Type**: float
- **Purpose**: Typical-p sampling parameter

### `mirostat_target`
- **Type**: float
- **Purpose**: Target entropy for Mirostat sampling

### `mirostat_lr`
- **Type**: float
- **Purpose**: Learning rate for Mirostat sampling

### `parallel_tool_calls`
- **Type**: boolean
- **Purpose**: Allow concurrent tool invocations
- **Example**: `parallel_tool_calls: true`

### `max_completion_tokens`
- **Type**: positive integer
- **Purpose**: Reasoning-aware token budget (alternative to `max_tokens`)

### `prompt_cache_key`
- **Type**: String
- **Purpose**: Session affinity key for KV cache reuse
- **Example**: `prompt_cache_key: "user-42"`

### `prompt_cache_isolation_key`
- **Type**: String
- **Purpose**: Namespacing key for KV cache separation across users/tenants

### `prompt_truncate_len`
- **Type**: positive integer
- **Purpose**: Truncate prompts to this many tokens before sending

### `safe_tokenization`
- **Type**: boolean
- **Purpose**: Reject special tokens injected via user content
- **Example**: `safe_tokenization: true`

### `response_format`
- **Type**: map
- **Purpose**: Raw `response_format` field (escape hatch for advanced cases — prefer `fireworks_structured_output_mode`)

### `fireworks_structured_output_mode`
- **Type**: `:auto` | `:json_schema` | `:tool`
- **Default**: `:auto` (native `response_format: json_schema` with strict enforcement)
- **Purpose**: Strategy for `generate_object/4`
- **Example**: `fireworks_structured_output_mode: :tool`

### `fireworks_json_schema_strict`
- **Type**: boolean
- **Default**: `true`
- **Purpose**: When `true`, enforces `additionalProperties: false` and marks all properties required on the json_schema response_format

### `perf_metrics_in_response`
- **Type**: boolean
- **Purpose**: Include latency/throughput metrics in the response body

### `raw_output`
- **Type**: boolean
- **Purpose**: Return low-level model interaction details in the response

### `speculation`
- **Type**: map
- **Purpose**: Speculative decoding configuration

### `prediction`
- **Type**: map
- **Purpose**: Predicted output for speculative decoding

### `metadata`
- **Type**: map
- **Purpose**: Arbitrary metadata stored on the request for tracing/distillation

### `reasoning_effort` (core option)
- **Type**: `:none` | `:minimal` | `:low` | `:medium` | `:high` | `:xhigh` | `:default`
- **Purpose**: Control reasoning depth on reasoning-capable models
- **Note**: Fireworks accepts an additional `"max"` string value not covered by the core schema — pass it via `provider_options: [reasoning_effort: "max"]`

## Structured Output

Three strategies, selectable via `fireworks_structured_output_mode`:

```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]

# Default: native response_format json_schema with strict enforcement
ReqLLM.generate_object(
  "fireworks_ai:accounts/fireworks/models/glm-5",
  "Generate a software engineer profile.",
  schema
)

# Fallback: tool-call workaround (older models or explicit preference)
ReqLLM.generate_object(
  "fireworks_ai:accounts/fireworks/models/glm-5",
  "Generate a profile.",
  schema,
  fireworks_structured_output_mode: :tool
)
```

| Mode | Wire format |
|---|---|
| `:auto` (default) | `response_format: json_schema` (strict) |
| `:json_schema` | Same as `:auto` |
| `:tool` | `tools[]` + forced `tool_choice` |

## Implementation Notes

### `max_tokens > 4096` requires streaming
Fireworks rejects non-streaming chat requests with `max_tokens` over 4096. ReqLLM caps the value automatically and logs a warning:

```
[warning] Fireworks rejects non-streaming requests with max_tokens > 4096; capping to 4096
```

For longer completions, switch to `ReqLLM.stream_text/3`.

### Tool message metadata stripped
The OpenAI envelope allows arbitrary `metadata` on messages; Fireworks 400s on it. ReqLLM strips message-level `metadata` from the encoded body. Top-level request `metadata` (passed as a provider option) is still forwarded.

### `tool_choice` shape translation
Canonical ReqLLM tool choice (`%{type: "tool", name: "..."}`) is auto-translated to OpenAI's `%{type: "function", function: %{name: "..."}}` form for Fireworks.

### `top_k`
`top_k` can be passed either as a core option or nested under `:provider_options`:

```elixir
ReqLLM.generate_text(model, "Hi", top_k: 40)
ReqLLM.generate_text(model, "Hi", provider_options: [top_k: 40])
```

### Streaming usage
`stream_options.include_usage: true` is set automatically so the final SSE chunk carries final token counts.

### Default receive timeout
Reasoning completions on K2.5-class models can run several minutes. The provider sets `receive_timeout: 300_000` (5 min) by default; override per request if needed.

### Unsupported endpoints
ReqLLM targets Fireworks's `/inference/v1/chat/completions` endpoint. Out of scope: legacy `/v1/completions`, Anthropic-shaped `/v1/messages` (use the [Anthropic provider](anthropic.md) instead), and platform automation APIs (accounts, datasets, deployments, fine-tuning, evals, LoRA, secrets).

## Resources

- [Fireworks Documentation](https://docs.fireworks.ai/)
- [Fireworks Models](https://fireworks.ai/models)
- [LLMDB.xyz](https://llmdb.xyz)
- [Model Specs Guide](model-specs.md)
