# OpenAI

Access GPT models including standard chat models and reasoning models (o1, o3, GPT-5).

ReqLLM also exposes a separate `openai_codex` provider for the ChatGPT Codex backend used by OAuth Codex tokens.

## Configuration

```bash
OPENAI_API_KEY=sk-...
```

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Use exact OpenAI IDs from [LLMDB.xyz](https://llmdb.xyz) when possible. For brand-new model IDs, local OpenAI-compatible servers, or proxies, use `ReqLLM.model!/1` with `provider: :openai`, an explicit `id`, and `base_url` when needed.

### OAuth Access Token (optional)

If you use OAuth instead of API keys, pass an access token and set auth mode:

```elixir
ReqLLM.generate_text(
  "openai:gpt-5-codex",
  "Write a test",
  auth_mode: :oauth,
  access_token: System.fetch_env!("OPENAI_ACCESS_TOKEN")
)
```

You can also pass these under `provider_options`.

### ChatGPT Codex Backend (`openai_codex`)

Use `openai_codex:*` when your token comes from the ChatGPT/Codex OAuth flow and you want requests routed to `https://chatgpt.com/backend-api/codex/responses` instead of platform OpenAI `/v1/responses`.

This provider is OAuth-only and resolves `chatgpt_account_id` in this order:

- explicit `provider_options: [chatgpt_account_id: "..."]`
- `accountId` / `account_id` in the oauth/auth JSON file
- JWT claim extraction from the access token

Example:

```elixir
ReqLLM.generate_text(
  "openai_codex:gpt-5.3-codex-spark",
  "Write a test for this function",
  provider_options: [
    auth_mode: :oauth,
    oauth_file: "/path/to/auth.json"
  ]
)
```

### OAuth Files (`oauth.json` / `auth.json`)

ReqLLM can also read provider credentials from a JSON file using the same shape used by `pi-ai`:

```json
{
  "openai-codex": {
    "type": "oauth",
    "access": "eyJ...",
    "refresh": "oai_rt_...",
    "expires": 1762857415123,
    "accountId": "user_123"
  }
}
```

When `auth_mode: :oauth` is enabled and no explicit `access_token` is passed, ReqLLM will:

- load credentials from `provider_options: [oauth_file: "..."]`
- accept `auth_file` as an alias
- fall back to `oauth.json` or `auth.json` in the current working directory
- refresh expired `openai-codex` credentials automatically and persist the updated file
- reuse `accountId` from the file or derive it from the refreshed access token for Codex requests

Example:

```elixir
ReqLLM.generate_text(
  "openai:gpt-5-codex",
  "Write a test",
  provider_options: [
    auth_mode: :oauth,
    oauth_file: "/path/to/oauth.json"
  ]
)
```

If you need to customize the refresh HTTP client, pass `oauth_http_options` under `provider_options`.

For `openai_codex`, you can also override backend request headers with:

- `provider_options: [chatgpt_account_id: "..."]`
- `provider_options: [codex_originator: "pi"]`

ReqLLM applies the complete Responses Lite wire profile when the Codex model catalog marks a model with `use_responses_lite: true`. The bundled catalog currently enables that profile for GPT-5.6 Sol, Terra, and Luna. Explicit model specs can provide updated provider metadata under `extra.openai_codex.use_responses_lite`.

Responses Lite is an internal Codex backend contract, not a mode of the public OpenAI Responses API. It sends instructions and client-executed tools as input items, uses persistent reasoning context, disables parallel tool calls, and marks the request with the Codex Responses Lite header. The canonical behavior is defined by the [Codex model metadata](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/openai_models.rs) and [Responses Lite contract tests](https://github.com/openai/codex/blob/main/codex-rs/core/tests/suite/responses_lite.rs).

## Attachments

OpenAI Chat Completions API only supports image attachments (JPEG, PNG, GIF, WebP).
OpenAI Responses models also support image and PDF file inputs. Inline and URL
attachments continue to work as before.

### Reusable OpenAI files

`ReqLLM.Providers.OpenAI.Files` exposes the OpenAI Files lifecycle without
adding uploads to the common provider behaviour. Uploading once can avoid
repeating a large inline payload across Responses calls:

```elixir
alias ReqLLM.Message.ContentPart
alias ReqLLM.Providers.OpenAI.Files

{:ok, file} =
  Files.upload(
    ContentPart.file(pdf_bytes, "report.pdf", "application/pdf"),
    purpose: :user_data,
    expires_after: 86_400
  )

context =
  ReqLLM.Context.new([
    ReqLLM.Context.user([
      ContentPart.text("Summarize this report."),
      file
    ])
  ])

{:ok, response} = ReqLLM.generate_text("openai:gpt-5", context)
```

`Files.upload/2` accepts an inline file `ContentPart`, a local path, or an
explicit `{:binary, data, filename, media_type}` tuple. It returns the same
owned `ContentPart` shape documented in [Data Structures](data-structures.md),
including OpenAI ownership, purpose, filename, media type, size, status, and
expiry when available. Inline inputs also include a locally calculated SHA-256.
Local paths are streamed into the multipart request instead of being loaded
into one large binary.

Lifecycle operations remain provider-scoped:

```elixir
{:ok, current} = Files.retrieve(file)
{:ok, %Files.Page{files: files, has_more: has_more}} =
  Files.list(purpose: :user_data, limit: 100)

{:ok, true} = Files.delete(current)
```

OpenAI retains most uploaded files until they are deleted. Use
`:expires_after` when supported by the selected purpose, or delete references
when they are no longer needed. Deletion accepts a known-expired reference so
cleanup remains possible. The caller remains responsible for retention,
pagination, and cleanup; ReqLLM does not run background workers or upload
inputs automatically.

Treat returned references as sensitive. Regular inspection and ReqLLM
telemetry redact provider IDs, URLs, credentials, and file contents. Use
`ContentPart.provider_file_reference/1` only when the complete provider record
is required.

See the [OpenAI Files API reference](https://platform.openai.com/docs/api-reference/files)
for current purposes, retention rules, and service limits.

## Dual API Architecture

OpenAI provider automatically routes between two APIs based on model metadata:

- **Chat Completions API**: Standard GPT models (gpt-4o, gpt-4-turbo, gpt-3.5-turbo)
- **Responses API**: Reasoning models (o1, o3, o4-mini, gpt-5) with extended thinking

### Chat Completions responsibilities

The V1 provider callbacks and transports remain unchanged. Internally, Chat
Completions responsibilities are intentionally narrow:

| Responsibility | Before | Current owner |
| --- | --- | --- |
| Select Chat Completions or Responses and attach the Req pipeline | `ReqLLM.Providers.OpenAI` | `ReqLLM.Providers.OpenAI` |
| Implement the Chat Completions driver callbacks and assemble its Finch request | `ReqLLM.Providers.OpenAI.ChatAPI` | `ReqLLM.Providers.OpenAI.ChatAPI` |
| Build the exact request envelope used by both Req and Finch | private functions mixed into `ChatAPI` | <code>ReqLLM.Providers.OpenAI.ChatAPI.Request</code> |
| Encode OpenAI-compatible messages and decode buffered/SSE wire data | `ReqLLM.Provider.Defaults` | `ReqLLM.Provider.Defaults` |
| Accumulate chunks and materialize canonical responses | `ReqLLM.Provider.ChunkAccumulator` and response builders | unchanged shared modules |

The request-envelope seam removes duplicate strict-tool and parallel-tool
normalization by reusing `ReqLLM.Providers.OpenAI.AdapterHelpers`. SSE decoding,
transport construction, and response handoff already have single owners, so they
remain in place. This is an internal refactor: Req remains the buffered
transport, Finch remains the streaming transport, and the existing
`ReqLLM.Provider` callbacks and request/response shapes are preserved.

## Provider Options

Passed via `:provider_options` keyword:

### `max_completion_tokens`

- **Type**: Integer
- **Purpose**: Required for reasoning models (o1, o3, gpt-5)
- **Note**: ReqLLM auto-translates `max_tokens` to `max_completion_tokens` for reasoning models
- **Example**: `provider_options: [max_completion_tokens: 4000]`

### `openai_structured_output_mode`

- **Type**: `:auto` | `:json_schema` | `:tool_strict`
- **Default**: `:auto`
- **Purpose**: Control structured output strategy
- **`:auto`**: Use json_schema when supported, else strict tools
- **`:json_schema`**: Force response_format with json_schema
- **`:tool_strict`**: Force strict: true on function tools
- **Example**: `provider_options: [openai_structured_output_mode: :json_schema]`

### `response_format`

- **Type**: Map
- **Purpose**: Custom response format configuration
- **Example**:
  ```elixir
  provider_options: [
    response_format: %{
      type: "json_schema",
      json_schema: %{
        name: "person",
        schema: %{type: "object", properties: %{name: %{type: "string"}}}
      }
    }
  ]
  ```

### `openai_parallel_tool_calls`

- **Type**: Boolean | nil
- **Default**: `nil`
- **Purpose**: Override parallel tool call behavior
- **Example**: `provider_options: [openai_parallel_tool_calls: false]`

### `reasoning_effort`

- **Type**: `:low` | `:medium` | `:high`
- **Purpose**: Control reasoning effort
- **Example**: `reasoning_effort: :high`

### `service_tier`

- **Type**: `:auto` | `:default` | `:flex` | `:priority` | String
- **Purpose**: Service tier for request prioritization
- **Example**: `service_tier: :auto`

### `seed`

- **Type**: Integer
- **Purpose**: Set seed for reproducible outputs
- **Example**: `provider_options: [seed: 42]`

### `logprobs`

- **Type**: Boolean
- **Purpose**: Request log probabilities
- **Example**: `provider_options: [logprobs: true, top_logprobs: 3]`

### `top_logprobs`

- **Type**: Integer (1-20)
- **Purpose**: Number of log probabilities to return
- **Requires**: `logprobs: true`
- **Example**: `provider_options: [logprobs: true, top_logprobs: 5]`

### `user`

- **Type**: String
- **Purpose**: Track usage by user identifier
- **Example**: `provider_options: [user: "user_123"]`

### `verbosity`

- **Type**: `"low"` | `"medium"` | `"high"`
- **Default**: `"medium"`
- **Purpose**: Control output detail level
- **Example**: `provider_options: [verbosity: "high"]`

### `openai_stream_transport`

- **Type**: `:sse` | `:websocket`
- **Default**: `:sse`
- **Purpose**: Select the streaming transport for Responses models
- **Note**: `:websocket` currently applies to OpenAI Responses models only
- **Example**: `provider_options: [openai_stream_transport: :websocket]`

### Embedding Options

#### `dimensions`

- **Type**: Positive integer
- **Purpose**: Control embedding dimensions (model-specific ranges)
- **Example**: `provider_options: [dimensions: 512]`

#### `encoding_format`

- **Type**: `"float"` | `"base64"`
- **Purpose**: Format for embedding output
- **Example**: `provider_options: [encoding_format: "base64"]`

### Responses API Resume Flow

#### `previous_response_id`

- **Type**: String
- **Purpose**: Resume tool calling flow from previous response
- **Example**: `provider_options: [previous_response_id: "resp_abc123"]`

#### `tool_outputs`

- **Type**: List of `%{call_id, output}` maps
- **Purpose**: Provide tool execution results for resume flow
- **Example**: `provider_options: [tool_outputs: [%{call_id: "call_1", output: "result"}]]`

## WebSocket Mode

ReqLLM keeps SSE as the default transport for OpenAI streaming, but Responses models can opt into OpenAI WebSocket mode per request:

```elixir
{:ok, stream_response} =
  ReqLLM.stream_text(
    "openai:gpt-5",
    "Write a short summary",
    provider_options: [openai_stream_transport: :websocket]
  )

text = ReqLLM.StreamResponse.text(stream_response)
usage = ReqLLM.StreamResponse.usage(stream_response)
```

Use this when you want a call-scoped WebSocket transport while keeping the existing `StreamResponse` API. SSE remains the safer default for broad provider parity and existing fixture coverage.

## Realtime API

ReqLLM also exposes an experimental low-level Realtime WebSocket client for session-oriented workflows that do not fit `stream_text/3`:

```elixir
{:ok, session} = ReqLLM.OpenAI.Realtime.connect("gpt-realtime")

:ok =
  ReqLLM.OpenAI.Realtime.session_update(session, %{
    "type" => "realtime",
    "instructions" => "Be concise and friendly."
  })

{:ok, event} = ReqLLM.OpenAI.Realtime.next_event(session)

:ok = ReqLLM.OpenAI.Realtime.close(session)
```

This API is intentionally low-level. You send JSON events, receive JSON events, and manage the session lifecycle explicitly. Existing `next_event/2` calls continue to return the decoded OpenAI event unchanged.

For consumers that already understand `ReqLLM.StreamEvent`, use the additive projected view:

```elixir
{:ok, projected} = ReqLLM.OpenAI.Realtime.next_projected_event(session)

projected.type
#=> "response.output_text.delta"

projected.native
#=> the native event with sensitive payloads redacted

projected.stream_events
#=> [%ReqLLM.StreamEvent{type: :text_delta, data: "[REDACTED]", ...}]
```

Pass `payloads: :raw` only when that consumer is authorized to retain text, audio transcripts, tool arguments/results, and provider error messages. Raw audio deltas, input transcription, session/control events, rate limits, MCP and other provider-native tools, and recoverable session errors remain native-only because ReqLLM has no exact portable event for them.

The experimental projection is intentionally narrow:

| OpenAI Realtime event | Portable projection |
| --- | --- |
| `response.created` | `:start` when the resolved session model is available |
| `response.output_text.delta` | `:text_delta` |
| `response.output_audio_transcript.delta` | `:text_delta` with `modality: :audio_transcript` |
| application `response.output_item.added` | `:tool_call_start` |
| `response.function_call_arguments.delta` / `.done` | `:tool_call_delta` / `:tool_call` |
| application `conversation.item.done` function output | `:tool_result` |
| `response.done` | optional `:usage`, then one `:finish`, `:cancelled`, or terminal `:error` |

All other events have an empty `stream_events` list and remain available through `native`. This includes top-level `error` events because OpenAI defines many of them as recoverable session errors, while canonical `StreamEvent` errors are terminal. See the [OpenAI Realtime server-event reference](https://platform.openai.com/docs/api-reference/realtime-server-events) for the provider event catalog.

`response.created` starts a canonical response lifecycle, and `response.done` contributes usage followed by exactly one completion, cancellation, or terminal error event. OpenAI event, response, item, call, conversation, session, index, and sequence identifiers are retained for correlation. Reconnecting creates a new provider session; ReqLLM does not hide reconnection or replay events. Applications or Jido continue to own session hosting, reconnection, tool execution, and follow-up calls.

## Usage Metrics

OpenAI provides comprehensive usage data including:

- `reasoning_tokens` - For reasoning models (o1, o3, gpt-5)
- `cached_tokens` - Cached input tokens
- Standard input/output/total tokens and costs

### Web Search (Responses API)

Models using the Responses API (o1, o3, gpt-5) support web search tools:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-5-mini",
  "What are the latest AI announcements?",
  tools: [%{"type" => "web_search"}]
)

# Access web search usage
response.usage.tool_usage.web_search
#=> %{count: 2, unit: "call"}

# Access cost breakdown
response.usage.cost
#=> %{tokens: 0.002, tools: 0.02, images: 0.0, total: 0.022}
```

Responses API server-side tools may also appear in `response.message.tool_calls` as builtin records (for example `web_search_call` or `file_search_call`). They are preserved for observability, but the provider already executed them: do not replay them as local tool calls. `ReqLLM.Response.classify/1` and `ReqLLM.StreamResponse.classify/1` treat builtin-only responses as final answers.

### Code Interpreter (Responses API)

Models using the Responses API support the Code Interpreter tool, which runs Python code in a sandboxed container. Pass the tool as a map and ReqLLM will forward it unchanged to OpenAI:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "openai:gpt-5-mini",
  "What is the factorial of 12804/53 + 300? Solve with Python.",
  tools: [%{
    "type" => "code_interpreter",
    "container" => %{"type" => "auto", "memory_limit" => "4g"}
  }]
)

# Access the raw code interpreter output items
response.provider_meta["code_interpreter"]["items"]
#=> [
#=>   %{
#=>     "type" => "code_interpreter_call",
#=>     "code" => "from fractions import Fraction...",
#=>     "status" => "completed",
#=>     ...
#=>   }
#=> ]

# Access code interpreter usage
response.usage.tool_usage.code_interpreter
#=> %{count: 1, unit: :call}
```

The container value may also be an existing container ID string:

```elixir
tools: [%{"type" => "code_interpreter", "container" => "cntr_abc123"}]
```

Code Interpreter is a server-side builtin: the provider executes the code and returns the result items. Do not replay them as local tool calls. `ReqLLM.Response.classify/1` treats these responses as final answers.

### Image Generation

Image generation costs are tracked separately:

```elixir
{:ok, response} = ReqLLM.generate_image("openai:gpt-image-1", prompt)

response.usage.image_usage
#=> %{generated: %{count: 1, size_class: "1024x1024"}}

response.usage.cost
#=> %{tokens: 0.0, tools: 0.0, images: 0.04, total: 0.04}
```

See the [Image Generation Guide](image-generation.md) for more details.

## Resources

- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference)
- [Model Overview](https://platform.openai.com/docs/models)
