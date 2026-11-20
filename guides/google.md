# Google (Gemini)

Access Gemini models with built-in web grounding and thinking capabilities.

## Configuration

```bash
GOOGLE_API_KEY=AIza...
```

Requests send the API key in the `x-goog-api-key` header by default, including
streaming, embeddings, image generation, and cached-content operations. This
keeps the credential out of request URLs and URL-based logs.

For proxies that require query authentication, pass
`provider_options: [google_auth_header: false]`. For `Google.CachedContent`
functions, pass `google_auth_header: false` directly in the options.

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Use exact Gemini IDs from [LLM Catalog](https://llmcatalog.dev) when possible. If you need to work ahead of the registry, use `ReqLLM.model!/1` to build a full explicit model spec.

## Decisions API

Use `ReqLLM.evaluate/4` with Gemini Decisions for boolean checks, choices, and
rubric scores. Results include probabilities and confidence instead of generated
text. The adapter calls `POST /v1beta/decisions` with the same `GOOGLE_API_KEY`
configuration as other Google requests.

For a model not yet included in your LLMDB catalog, use an explicit model spec:

```elixir
model = ReqLLM.model!(%{
  provider: :google,
  id: "gemini-decision-1",
  capabilities: %{evaluate: true, chat: false},
  execution: %{
    evaluate: %{
      supported: true,
      family: "google_decisions",
      wire_protocol: "google_decisions",
      transport: "http",
      path: "/decisions",
      provider_model_id: "gemini-decision-1"
    }
  }
})

{:ok, result} = ReqLLM.evaluate(model, "The parcel arrived with a cracked mug.", %{
  damaged: %{type: :boolean, instructions: "Is the item damaged?"},
  team: %{
    type: :choice,
    instructions: "Which team should handle this?",
    criteria: %{billing: "Payment problems", support: "Product problems"}
  },
  severity: %{
    type: :score,
    instructions: "How severe is the problem?",
    criteria: ["Minor", "Major", "Critical"]
  }
})

result.object["damaged"]["probability"]
result.object["team"]["probabilities"]
result.object["severity"]["score"]
```

Boolean questions map to Google's `noul` type; responses expose `type: "boolean"`
and `"probability"`. Native `:noul` questions are accepted too. Choice and score
answers retain `"confidence"`, `"probabilities"`, and the score's `"legend"`.
Scores are weighted averages of zero-based rubric levels. Original response data,
including usage by modality, remains in `result.provider_meta.raw_response`.

Plain map and list states are serialized as JSON text. For multimodal evaluation,
pass exactly one user message in a context:

```elixir
alias ReqLLM.Message.ContentPart

context = ReqLLM.Context.new([
  ReqLLM.Context.user([
    ContentPart.text("Inspect the item in this photo.\n"),
    ContentPart.image(File.read!("item.png"), "image/png", %{resolution: "low"}),
    ContentPart.file(File.read!("receipt.pdf"), "receipt.pdf", "application/pdf")
  ])
])

ReqLLM.evaluate(model, context, %{
  damaged: %{type: :boolean, instructions: "Is the photographed item damaged?"}
})
```

`ContentPart.file/4` accepts audio, video, and PDF bytes with their actual MIME
type. Image and video URL parts support HTTPS URLs; use `mime_type` metadata if
the URL does not identify its file format. `ContentPart.file_id/2` accepts a
Google Files API URI. Image and video parts accept `resolution` metadata.
Conversation history, system messages, tool calls, YouTube URLs, and `gs://`
URIs are unsupported. The API requires `v1beta` and supports up to 1,000 questions
per request, with 2–255 options per choice or score question. It has no streaming
mode. See [Google's Decisions API documentation](https://aistudio.google.com/docs/decisions-api)
for the current limits and supported media formats.

**Vertex AI availability:** Google currently lists Cloud support as coming soon.
Use the direct `:google` provider; `:google_vertex` cannot execute Decisions
requests yet. See the [launch announcement](https://blog.google/innovation-and-ai/technology/developers-tools/gemini-decisions-api/).

## Function Calling

Use `tool_choice: :validated` (or `"validated"`) with `tools` to enable Gemini's
`VALIDATED` function-calling mode. It enforces function-schema adherence while
allowing the model to respond with either natural language or a function call.

```elixir
ReqLLM.generate_text("google:gemini-2.5-flash", "What is the weather in Madrid?",
  tools: tools,
  tool_choice: :validated
)
```

The same option works with `ReqLLM.stream_text/3`. See Google's
[function-calling modes reference](https://ai.google.dev/gemini-api/docs/generate-content/function-calling#function-calling-modes).

Gemini 3 can return a tool call and, on a later turn, a final answer that
matches a response schema. Pass both `tools` and `output: ReqLLM.Output.object(...)`
to `ReqLLM.generate_text/3`:

```elixir
ReqLLM.generate_text(
  "google:gemini-3-flash",
  "Look up the weather in Madrid, then return a summary.",
  tools: tools,
  output: ReqLLM.Output.object(summary: [type: :string, required: true])
)
```

A tool-call turn exposes tool calls and leaves the object unset. A JSON turn
exposes the object. Models before Gemini 3 still return a parameter error
(`tools are not supported`).

## Provider Options

Passed via `:provider_options` keyword:

### `google_auth_header`
- **Type**: Boolean
- **Default**: `true`
- **Purpose**: Send the API key in the `x-goog-api-key` header
- **Compatibility**: Set to `false` to send the credential in the `key` URL query parameter
- **Example**: `provider_options: [google_auth_header: false]`

### `google_api_version`
- **Type**: `"v1"` | `"v1beta"`
- **Default**: `"v1"`
- **Purpose**: Select API version (v1beta required for grounding)
- **Example**: `provider_options: [google_api_version: "v1beta"]`
- **Note**: Auto-set to v1beta when `google_grounding` is used

### `google_grounding`
- **Type**: Map
- **Purpose**: Enable Google Search grounding (requires v1beta)
- **Modern (Gemini 2.5)**: `%{enable: true}`
- **Legacy (Gemini 1.5)**: `%{dynamic_retrieval: %{mode: "MODE_DYNAMIC", dynamic_threshold: 0.7}}`
- **Example**: `provider_options: [google_grounding: %{enable: true}]`
- **Cost tracking**: Usage tracked in `response.usage.tool_usage.web_search` with `unit: "query"`

### `google_url_context`
- **Type**: Boolean
- **Purpose**: Enable URL context grounding - allows model to fetch and use content from specific URLs
- **Example**: `provider_options: [google_url_context: true]`
- **Note**: Requires v1beta (default)

### `google_thinking_budget`
- **Type**: Non-negative integer
- **Purpose**: Control thinking tokens for Gemini 2.5 models
- **`0`**: Disable thinking
- **Omit**: Dynamic allocation (default)
- **Example**: `provider_options: [google_thinking_budget: 4096]`

### `google_include_thoughts`
- **Type**: Boolean
- **Default**: `true` for chat (including streaming); structured output always disables summaries
- **Purpose**: Request thought summaries when a thinking budget or level is configured. Set to `false` when the caller does not consume summaries; this preserves the thinking budget/level.
- **Example**: `provider_options: [google_thinking_budget: 2048, google_include_thoughts: false]`
- **Note**: Has no effect when thinking is disabled or no thinking budget/level is configured.

### `google_safety_settings`
- **Type**: List of maps
- **Purpose**: Configure content safety filters
- **Categories**: `HARM_CATEGORY_HATE_SPEECH`, `HARM_CATEGORY_DANGEROUS_CONTENT`, `HARM_CATEGORY_HARASSMENT`, `HARM_CATEGORY_SEXUALLY_EXPLICIT`
- **Thresholds**: `BLOCK_NONE`, `BLOCK_ONLY_HIGH`, `BLOCK_MEDIUM_AND_ABOVE`, `BLOCK_LOW_AND_ABOVE`
- **Example**:
  ```elixir
  provider_options: [
    google_safety_settings: [
      %{category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
    ]
  ]
  ```

### Model compatibility

Gemini 3 and later do not support `google_candidate_count`. ReqLLM omits
`candidateCount` for these models and rejects an explicit value.

Gemini 3.6 and later, and Gemini 3.5 Flash-Lite, do not accept `temperature`,
`top_p`, `top_k`, `reasoning_token_budget`, or `google_thinking_budget` in text
and structured-output requests. Use `reasoning_effort` or
`google_thinking_level` to control reasoning. Gemini 3.8 Flash supports `low`,
`medium`, and `high`; an explicit `minimal` level is rejected.

These checks also apply to Gemini models on Google Vertex AI.

### `google_candidate_count`
- **Type**: Positive integer
- **Default**: `1`
- **Purpose**: Generate multiple candidates on Gemini 2.x (only first returned)
- **Example**: `provider_options: [google_candidate_count: 3]`

### Embedding Options

#### `dimensions`
- **Type**: `128..3072`
- **Purpose**: Control embedding vector dimensions
- **Recommended**: `768`, `1536`, or `3072`
- **Example**: `provider_options: [dimensions: 768]`

#### `task_type`
- **Type**: String
- **Purpose**: Specify embedding task type
- **Values**: `RETRIEVAL_QUERY`, `RETRIEVAL_DOCUMENT`, `SEMANTIC_SIMILARITY`, `CLASSIFICATION`
- **Example**: `provider_options: [task_type: "RETRIEVAL_QUERY"]`

#### `title`
- **Type**: String
- **Purpose**: Document title for better embedding quality
- **Example**: `provider_options: [title: "Product Documentation", task_type: "RETRIEVAL_DOCUMENT"]`

## Grounding Cost Tracking

When using Google Search grounding, usage and costs are tracked in `response.usage`:

```elixir
{:ok, response} = ReqLLM.generate_text(
  "google:gemini-3-flash-preview",
  "What are the latest developments in quantum computing?",
  provider_options: [google_grounding: %{enable: true}]
)

# Access grounding/search usage
response.usage.tool_usage.web_search
#=> %{count: 3, unit: "query"}

# Access cost breakdown
response.usage.cost
#=> %{tokens: 0.001, tools: 0.015, images: 0.0, total: 0.016}
```

Google grounding uses `unit: "query"` to track the number of search queries performed.

## Text thought signatures

Gemini can return `thoughtSignature` on ordinary text parts, even without
`thought: true`. ReqLLM stores these signatures in each text content part's
`metadata[:thought_signature]`. Decoded streaming text chunks use the same
metadata key.

Buffered responses and assembled streaming responses preserve signed text
parts in both `response.message` and `response.context`. Distinct signed parts
stay separate. An empty text part with a signature also stays in the message,
but does not add visible text to `ReqLLM.Response.text/1`.

To continue a conversation, reuse `response.context` and append the next user
message or tool result. ReqLLM sends each text signature back on its original
part. Rebuilding history from `ReqLLM.Response.text/1` alone loses the signatures
and part boundaries. Treat signatures as opaque values. Do not edit them or
merge signed text parts.

This behavior also applies to Gemini on Google Vertex AI. Thinking signatures
remain in `message.reasoning_details`; text signatures do not create reasoning
details.

## Wire Format Notes

- Endpoint: `/models/{model}:generateContent`
- Auth: API key in query param or header
- System: Separate `systemInstruction` field
- Safety: Gemini-specific safety configuration

All differences handled automatically by ReqLLM.

For tool-only assistant turns, ReqLLM emits function-call parts without adding an
empty text part. Existing thinking, nonempty text, and tool-call signatures are
retained. Append the matching tool results before continuing the conversation.
This also applies to Gemini on Google Vertex AI.

## Assistant Prefill

Gemini 3.5 Flash-Lite and Gemini 3.6 or later models cannot end a text or object
request with a non-empty assistant turn. Older models retain prefill support.
This also applies to streaming requests. The local error is `ReqLLM.Error.Invalid.Parameter`.
ReqLLM checks the context before it sends the request. For `stream_text/3`, this
error is inside the streaming error tuple. System messages do not count as
conversation turns. Empty turns do not change the last non-empty turn.

Append a user message to request a response. For a tool call, append the tool
result before you continue the conversation.

See Google's [prefill migration guide](https://ai.google.dev/gemini-api/docs/generate-content/whats-new-gemini-3.6#2-prefilled-model-turn-validation).

## Resources

- [Google AI Documentation](https://ai.google.dev/docs)
- [Gemini API Reference](https://ai.google.dev/api/rest)
