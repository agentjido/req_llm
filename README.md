# ReqLLM

[![Hex.pm](https://img.shields.io/hexpm/v/req_llm.svg)](https://hex.pm/packages/req_llm)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/req_llm/)
[![CI](https://github.com/agentjido/req_llm/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/req_llm/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/req_llm.svg)](https://github.com/agentjido/req_llm/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> **Join the community!** Come chat about building AI tools with Elixir and coding Elixir with LLMs in [The Swarm: Elixir AI Collective](https://jido.run/discord) Discord server.

A [Req](https://github.com/wojtekmach/req)- and [Finch](https://github.com/sneako/finch)-backed package to call LLM APIs that standardizes requests and responses across providers.

## Why Req LLM?

LLM APIs are inconsistent. ReqLLM provides a unified, idiomatic Elixir interface with standardized requests and responses across providers.

**Unified architecture:**

- **High-level API** – Vercel AI SDK-inspired functions (`generate_text/3`, `stream_text/3`, `generate_object/4` and more) that normalize requests and responses across providers.
- **Provider transports** – Req powers request/response calls; Finch powers streaming. Dedicated provider modules or the shared catalog gateway translate model metadata, options, bodies, and responses behind the same public API.

### Provider Integrations and Model Support

ReqLLM gets model metadata from [LLMDB](https://llmcatalog.dev). It sends a
request through one of two integration paths:

- **Dedicated provider module**: A registered ReqLLM module owns the provider's
  authentication, routes, wire format, and special behavior.
- **Shared catalog gateway**: The provider has no dedicated ReqLLM module.
  LLMDB supplies an execution contract, and ReqLLM sends the request through
  its shared OpenAI Chat Completions adapter.

These paths describe request routing. They do not describe support quality. A
model can be in LLMDB before ReqLLM has verified its API behavior. Support tiers
such as **First-class** describe fixture evidence for an exact model and
operation. See [Model Support Evidence](guides/model-support.md) for that detail.

Community contributions can add either integration path. After a
provider-specific module is merged, it is a dedicated provider module. The
origin of the contribution does not change its integration type.

#### Hosted APIs With Dedicated Modules

Each provider in this table has a registered module in ReqLLM. Main operations
show the module's broad scope. The selected model can support fewer operations.

| Provider | ID | Main operations | Guide |
|---|---|---|---|
| [Alibaba Cloud Bailian](https://llmcatalog.dev/?providers=alibaba) | `alibaba` | text, OCR, transcription | — |
| [Alibaba Cloud Bailian (China)](https://llmcatalog.dev/?providers=alibaba_cn) | `alibaba_cn` | text, OCR, transcription | — |
| [Amazon Bedrock](https://llmcatalog.dev/?providers=amazon_bedrock) | `amazon_bedrock` | text, embedding | [Guide](guides/amazon_bedrock.md) |
| [Anthropic](https://llmcatalog.dev/?providers=anthropic) | `anthropic` | text | [Guide](guides/anthropic.md) |
| Atlas Cloud | `atlascloud` | text | — |
| [Azure OpenAI](https://llmcatalog.dev/?providers=azure) | `azure` | text, embedding, image | [Guide](guides/azure.md) |
| [Cerebras](https://llmcatalog.dev/?providers=cerebras) | `cerebras` | text | [Guide](guides/cerebras.md) |
| [Cheaper Inference](https://api.cheaperinference.com/docs) | `cheaperinference` | text | — |
| [Cohere](https://llmcatalog.dev/?providers=cohere) | `cohere` | text, rerank | — |
| [DeepSeek](https://llmcatalog.dev/?providers=deepseek) | `deepseek` | text | [Guide](guides/deepseek.md) |
| [ElevenLabs](https://llmcatalog.dev/?providers=elevenlabs) | `elevenlabs` | speech | — |
| [Fireworks AI](https://llmcatalog.dev/?providers=fireworks_ai) | `fireworks_ai` | text | [Guide](guides/fireworks_ai.md) |
| [GitHub Copilot](https://llmcatalog.dev/?providers=github_copilot) | `github_copilot` | text | [Guide](guides/github_copilot.md) |
| [Google Gemini](https://llmcatalog.dev/?providers=google) | `google` | text, embedding, image | [Guide](guides/google.md) |
| [Google Vertex AI](https://llmcatalog.dev/?providers=google_vertex) | `google_vertex` | text | [Guide](guides/google_vertex.md) |
| [Groq](https://llmcatalog.dev/?providers=groq) | `groq` | text, speech, transcription | [Guide](guides/groq.md) |
| [Inference.net](https://inference.net/models) | `inference` | text, structured output, streaming | [Guide](guides/inference.md) |
| [Meta Model API](https://llmcatalog.dev/?providers=meta) | `meta` | text | [Guide](guides/meta.md) |
| [MiniMax](https://llmcatalog.dev/?providers=minimax) | `minimax` | text, video | — |
| [Mistral](https://llmcatalog.dev/?providers=mistral) | `mistral` | text, embedding | — |
| [Moonshot AI](https://llmcatalog.dev/?providers=moonshotai) | `moonshotai` | text | [Guide](guides/moonshot_ai.md) |
| [NEAR AI Cloud](https://llmcatalog.dev/?providers=nearai) | `nearai` | text | [Guide](guides/nearai.md) |
| [OpenAI](https://llmcatalog.dev/?providers=openai) | `openai` | text, embedding, image, speech, transcription | [Guide](guides/openai.md) |
| OpenAI Codex | `openai_codex` | text | [Guide](guides/openai.md#chatgpt-codex-backend-openai_codex) |
| [OpenRouter](https://llmcatalog.dev/?providers=openrouter) | `openrouter` | text, embedding, image | [Guide](guides/openrouter.md) |
| Reflection AI | `reflection` | text | [Guide](guides/reflection.md) |
| [StepFun China](https://llmcatalog.dev/?providers=stepfun) | `stepfun` | text, speech, transcription | [Guide](guides/stepfun.md) |
| [StepFun Global](https://llmcatalog.dev/?providers=stepfun_ai) | `stepfun_ai` | text, speech, transcription | [Guide](guides/stepfun.md) |
| [TypeSafe](https://llmcatalog.dev/?providers=typesafe) | `typesafe` | evaluation | [Example](#evaluation-models) |
| [Venice](https://llmcatalog.dev/?providers=venice) | `venice` | text | — |
| [xAI](https://llmcatalog.dev/?providers=xai) | `xai` | text, image | [Guide](guides/xai.md) |
| [Z.AI](https://llmcatalog.dev/?providers=zai) | `zai` | text | [Guide](guides/zai.md) |
| [Z.AI Coder](https://llmcatalog.dev/?providers=zai_coder) | `zai_coder` | text | [Guide](guides/zai_coder.md) |
| [Z.AI Coding Plan](https://llmcatalog.dev/?providers=zai_coding_plan) | `zai_coding_plan` | text | — |
| [Zenmux](https://llmcatalog.dev/?providers=zenmux) | `zenmux` | text, image | [Guide](guides/zenmux.md) |

#### Shared Catalog Gateway: No Dedicated Module

This path is for hosted APIs that use plain OpenAI Chat Completions with bearer
authentication. LLMDB must supply the base URL, route, wire protocol, and
authentication contract. ReqLLM then uses `ReqLLM.Providers.CatalogGateway`.
A dedicated provider module always takes priority when one is registered.

| Provider | ID | Main operations | Evidence |
|---|---|---|---|
| [LLM API](https://app.llmapi.ai/?utm_source=ff0a247d-c8ab-4f19-a982-c4ff915da268) | `llmapi` | text, structured output, streaming | [Recorded fixtures](guides/model-support.md#llmapi) |

Support on this path is limited to the LLMDB execution contract and the recorded
fixture evidence. A complete model spec can also use this path before the model
is in the catalog. See [Model Specs](guides/model-specs.md#openai-chat-completions-providers-without-a-reqllm-module).

#### Local and Self-Hosted Runtimes

These runtimes have dedicated ReqLLM modules. Their model IDs come from the
user's server, so the models do not need LLMDB catalog entries.

| Runtime | ID | Main operations | Guide |
|---|---|---|---|
| Ollama | `ollama` | text, structured output | [Guide](guides/ollama.md) |
| LM Studio | `lmstudio` | text, embedding | [Guide](guides/lmstudio.md) |
| vLLM | `vllm` | text | — |

\* _Streaming uses Finch directly due to known Req limitations with SSE responses._

## Installation

> **Security update:** ReqLLM 1.29.0 fixes
> [GHSA-6vww-5m28-f26v](https://github.com/agentjido/req_llm/security/advisories/GHSA-6vww-5m28-f26v).
> Versions 1.9.0 through 1.28.0 did not verify TLS certificates for affected
> WebSocket sessions. Users of OpenAI Responses WebSocket, Realtime, or Codex
> WebSocket sessions should upgrade. HTTP streaming is not affected.

### Igniter Installation (Recommended)

The fastest way to get started is with [Igniter](https://hex.pm/packages/igniter):

```bash
mix igniter.install req_llm
```

### Manual Installation

Add `req_llm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:req_llm, "~> 1.29"}
  ]
end
```

Then run:

```bash
mix deps.get
```

### Optional Provider Dependencies

Two providers rely on external authentication libraries that are **optional** —
they are not pulled in unless you add them yourself, so most users incur no extra
dependencies:

| Provider | Add to `deps` | Used for |
| --- | --- | --- |
| `amazon_bedrock` | `{:ex_aws_auth, "~> 1.5"}` | AWS Signature V4 request signing (IAM credentials, STS, bidirectional streaming) |
| `google_vertex` | `{:goth, "~> 1.4"}` | Google Cloud OAuth via Application Default Credentials, refresh tokens, workload identity, and the metadata server |

If you use one of these providers without the corresponding dependency, ReqLLM
raises a clear error telling you which package to add. (Amazon Bedrock's API-key
auth and Google Vertex's service-account JWT signing do not require these
libraries.)

## Quick Start

```elixir
# Keys are picked up from .env files or environment variables - see `ReqLLM.Keys`
model = "anthropic:claude-haiku-4-5"

ReqLLM.generate_text!(model, "Hello world")
#=> "Hello! How can I assist you today?"

schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!(model, "Generate a person", schema)
#=> %{name: "John Doe", age: 30}

output = ReqLLM.Output.array([name: [type: :string, required: true]])
{:ok, response} = ReqLLM.generate_text(model, "Generate three people", output: output)
ReqLLM.Response.output(response, output)
#=> [%{"name" => "Ada"}, %{"name" => "Grace"}, %{"name" => "Linus"}]

result = ReqLLM.Response.output_result(response, output)
result.valid?       #=> true
result.raw          # retained text or tool-call arguments
result.repairs      # visible legacy or callback repair attempts

{:ok, strict_response} = ReqLLM.generate_text(
  model,
  "Generate three people",
  output: output,
  output_validation: :strict
)

{:ok, image_response} = ReqLLM.generate_image("openai:gpt-image-1.5", "A simple red square")
image_bytes = ReqLLM.Response.image_data(image_response)
File.write!("red_square.png", image_bytes)

# Stream preview frames while the final image renders (OpenAI and Azure gpt-image models)
{:ok, image_stream} = ReqLLM.stream_image("openai:gpt-image-1.5", "A simple red square", partial_images: 2)
image_stream |> ReqLLM.StreamResponse.images() |> Enum.each(&IO.inspect(&1.metadata))
```

Note: Google image models gemini-2.5-flash-image and gemini-3-pro-image-preview reject :n; specify the image count in the prompt.

```elixir
{:ok, task} =
  ReqLLM.generate_video("minimax:MiniMax-H3",
    [prompt: "A boy playing basketball by the sea", first_frame_image: "https://example.com/frame.png"],
    duration: 5,
    resolution: "2K"
  )

{:ok, completed} = ReqLLM.wait_video("minimax:MiniMax-H3", task.task_id)
# completed.url is the video download URL

# Hailuo series (V1 API) returns a file_id instead of a url:
{:ok, task} =
  ReqLLM.generate_video("minimax:MiniMax-Hailuo-2.3",
    [prompt: "A cat", first_frame_image: "https://example.com/cat.png"],
    duration: 6,
    resolution: "768P"
  )

{:ok, completed} = ReqLLM.wait_video("minimax:MiniMax-Hailuo-2.3", task.task_id)
{:ok, file} = ReqLLM.retrieve_video_file("minimax:MiniMax-Hailuo-2.3", completed.file_id)
# file.url is the time-limited download URL

# Sensitive images: no public URL exposure. Auto-upload with {:upload, binary, media_type}:
# - H3 (V2 API): uploads to the platform and references mm_file://{file_id}
# - Hailuo (V1 API): inlines the image as a base64 data URL
{:ok, task} =
  ReqLLM.generate_video("minimax:MiniMax-Hailuo-2.3",
    [prompt: "The cat turns its head",
     first_frame_image: {:upload, image_bytes, "image/jpeg"}],
    duration: 6,
    resolution: "768P"
  )
```

```elixir
{:ok, response} = ReqLLM.generate_text(
  model,
  ReqLLM.Context.new([
    ReqLLM.Context.system("You are a helpful coding assistant"),
    ReqLLM.Context.user("Explain recursion in Elixir")
  ]),
  temperature: 0.7,
  max_tokens: 200
)


{:ok, response} = ReqLLM.generate_text(
  model,
  "What's the weather in Paris?",
  tools: [
    ReqLLM.tool(
      name: "get_weather",
      description: "Get current weather for a location",
      parameter_schema: [
        location: [type: :string, required: true, doc: "City name"]
      ],
      callback: {Weather, :fetch_weather, [:extra, :args]}
    )
  ]
)

# Streaming text generation
{:ok, response} = ReqLLM.stream_text(model, "Write a short story")
ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&IO.write/1)
|> Stream.run()

# Access usage metadata after streaming
usage = ReqLLM.StreamResponse.usage(response)
```

## Evaluation models

Evaluation models answer named questions about one text, JSON, or context state. They do
not need to support chat. `ReqLLM.evaluation_models/0` lists specs that
ReqLLM can call. Set `TYPESAFE_API_KEY`, `OPENROUTER_API_KEY`, or `OPENAI_API_KEY` in `.env`:

```elixir
questions = %{
  department: %{
    type: :choice,
    instructions: "Which team should handle this?",
    criteria: %{billing: "Billing and refunds", support: "Other requests"}
  },
  urgent: %{type: :boolean, instructions: "Is this urgent?"}
}

{:ok, result} = ReqLLM.evaluate("typesafe:jev-latest", %{message: "Refund me today"}, questions)
{:ok, routed} = ReqLLM.evaluate("openrouter:typesafe/jev-1.13", "Refund me today", questions)
{:ok, moving} = ReqLLM.evaluate("openrouter:~typesafe/jev-latest", "Refund me today", questions)
{:ok, decision} =
  ReqLLM.evaluate("openai:gpt-6-luna", %{message: "Refund me today"}, questions,
    provider_options: [openai: [safety_identifier: "tenant-123"]]
  )
result.object["department"]["choice"]
result.object["department"]["probabilities"]
result.object["urgent"]["probability"]
result.usage.input_tokens
```

Jev also supports `:score` questions with an ordered `criteria` list. Answers
use string keys. The `ReqLLM.Response` keeps the full provider response in
`provider_meta.raw_response`, including TypeSafe's `noul` value. `:boolean` is
the common ReqLLM name for that question. The moving OpenRouter ID keeps its
leading `~` in the request. An unknown model ID requires a full inline model
spec with evaluation capability and execution metadata. Catalog models without
evaluation support and gateways without an adapter return an error before HTTP.
OpenAI Decisions accepts string, map, list, and `ReqLLM.Context` state with boolean, choice, and
score questions. A context can carry images in user messages.
It returns refusals as `%{"type" => "refusal"}`. If OpenAI reports positive compute units without a
known tariff, ReqLLM keeps the count and leaves the cost unknown.
See [OpenRouter](guides/openrouter.md) for the gateway contract and an inline model example. See
[OpenAI](guides/openai.md) for the Decisions contract.
Use `generate_object/4` for text models that generate JSON objects; it is not a
Jev endpoint. Jev does not support text generation or streaming.

## Model routers

`ReqLLM.Router` is a behaviour for application-defined model routers. The
application router is a struct that implements one callback. ReqLLM gives it a
normalized request, and the callback returns a concrete `%LLMDB.Model{}`.

```elixir
defmodule MyApp.ModelRouter do
  @behaviour ReqLLM.Router

  defstruct fast_model: "openai:gpt-4o-mini",
            deep_model: "anthropic:claude-sonnet-4-5"

  @impl true
  def resolve(router, %ReqLLM.Router.Request{} = request) do
    model_spec =
      case request.routing_context do
        %{mode: :deep} -> router.deep_model
        _other -> router.fast_model
      end

    ReqLLM.model(model_spec)
  end
end

router = %MyApp.ModelRouter{}

ReqLLM.generate_text(router, "Hello",
  reasoning_effort: :medium,
  routing_context: %{mode: :fast}
)
```

The request has only two fields:

- `context` contains the normalized conversation and tools.
- `routing_context` contains opaque application data for model selection.

ReqLLM passes `routing_context` unchanged. It does not add the generation
operation, streaming state, output schema, provider credentials, generation
options, or transport options. If model selection needs one of these values,
the application must include it explicitly in `routing_context`.

The callback can use local rules, Jev, or another service. ReqLLM does not
include a built-in model-selection policy.

## Features

- **Provider-agnostic model registry**
  - Model metadata and execution contracts sourced from [LLMDB](https://llmcatalog.dev) through the `llm_db` dependency
  - Dedicated provider modules for provider-specific behavior, plus a shared catalog gateway for eligible OpenAI-compatible APIs
  - Text, embedding, image generation, speech, transcription, rerank and OCR operation metadata
  - Cost, context length, modality, capability and deprecation metadata included

- **Canonical data model**
  - Typed `Context`, `Message`, `ContentPart`, `Tool`, `StreamChunk`, `Response`, `Usage`
  - Multi-modal content parts (text, image URL, tool call, binary)
  - All structs implement `Jason.Encoder` for simple persistence / inspection

- **Unified client surface**
  - High-level Vercel-AI style helpers (`generate_text/3`, `stream_text/3`, `generate_object/4`, bang variants)
  - Req-backed request/response calls and Finch-backed streaming behind the same provider abstraction
  - Advanced Req request customization available for non-streaming use cases

- **Structured output generation**
  - `ReqLLM.Output` descriptors add text, object, array, choice, and arbitrary JSON contracts to `generate_text/3` and `stream_text/3`
  - `generate_object/4` and `stream_object/4` remain compatible object-generation conveniences
  - Zero-copy mapping to provider JSON-schema / function-calling endpoints
  - OpenAI native structured outputs with three modes (`:auto` (default), `:json_schema`, `:tool_strict`)

- **Provider-specific capabilities**
  - Anthropic web search for real-time content access (via `provider_options: [web_search: %{max_uses: 5}]`)
  - Extended thinking/reasoning for supported models
  - OpenAI Responses reasoning summaries, `reasoning.context` and context compaction (`ReqLLM.compact_context/3`) on OpenAI and Azure
  - Prompt caching for cost optimization
  - All provider-specific options documented in provider guides

- **Embedding generation**
  - Single or batch embeddings via `Embedding.generate/3` (Not all providers support this)
  - Automatic dimension / encoding validation and usage accounting

- **Production-grade streaming**
  - `stream_text/3` returns a `StreamResponse` with both real-time tokens and async metadata
  - Finch-based streaming with automatic connection pooling and configurable checkout timeouts
  - OpenAI Responses models can opt into WebSocket mode with `provider_options: [openai_stream_transport: :websocket]`
  - Concurrent metadata collection (usage, finish_reason) without blocking token flow
  - Works uniformly across providers with internal SSE / chunked-response adaptation

- **Experimental OpenAI realtime sessions**
  - `ReqLLM.OpenAI.Realtime` exposes a low-level WebSocket session API for Realtime models
  - Designed for explicit event-driven workflows that do not map cleanly to `stream_text/3`

- **Usage & cost tracking**
  - `response.usage` exposes normalized usage and best-effort USD cost from model metadata and provider response data

- **Schema-driven option validation**
  - All public APIs validate options with NimbleOptions; errors are raised as `ReqLLM.Error.Invalid.*` (Splode)

- **Automatic parameter translation & codecs**
  - Provider DSL translates canonical options (e.g. `max_tokens` -> `max_completion_tokens` for o1 & o3) to provider-specific names
  - Built-in OpenAI-style encoding/decoding with provider callback overrides for custom formats

- **Flexible model specification**
  - Accepts `"provider:model"`, tuples, `%LLMDB.Model{}` structs, and plain-map model specs
  - `ReqLLM.model!/1` is the recommended way to validate and normalize full model specs

- **Secure, layered key management** (`ReqLLM.Keys`)
  - Per-request override → application config → env vars / .env files
- **OAuth bearer auth for supported providers**
  - Direct `access_token` support for OpenAI and Anthropic
  - OpenAI can load and refresh `openai-codex` credentials from `oauth.json` / `auth.json`
  - `openai_codex:*` targets the ChatGPT Codex backend with OAuth-only auth and automatic account-id extraction

- **Extensive reliability tooling**
  - Fixture-backed test matrix (`LiveFixture`) supports cached, live, or provider-filtered runs
  - Dialyzer, Credo strict rules, and no-comment enforcement keep code quality high

## API Key Management

ReqLLM makes key management as easy and flexible as possible - this needs to _just work_.

**Please submit a PR if your key management use case is not covered**

Keys are pulled from multiple sources with clear precedence: per-request override → in-memory storage → application config → environment variables → .env files.

```elixir
# Store keys in memory (recommended)
ReqLLM.put_key(:openai_api_key, "sk-...")
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")

# Retrieve keys with source info
{:ok, key, source} = ReqLLM.get_key(:openai)
```

All functions accept an `api_key` parameter to override the stored key:

```elixir
ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello", api_key: "sk-ant-...")
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Story", api_key: "sk-ant-...")
```

By default, ReqLLM loads `.env` from the current working directory at startup when Mix is available (`mix run`, `mix test`, `iex -S mix`), and skips it in releases unless `load_dotenv: true` is explicitly configured. To disable loading under Mix as well:

```elixir
config :req_llm, load_dotenv: false
```

## Model Specs

ReqLLM can call models that are not in LLMDB yet. This is the recommended advanced
workflow for local development, debugging new releases, and custom provider setups.

Model lookup and request routing are separate. A complete model spec uses its
registered provider module when one exists. Otherwise, an eligible OpenAI Chat
Completions contract can use the shared catalog gateway.

See the [Model Specs](guides/model-specs.md) guide for the full explanation of
string specs, exact dated releases, `%LLMDB.Model{}` structs, and the full explicit
model specification path.

For backwards compatibility, you can pass a plain map directly to the major APIs.
The clearer path is to normalize it first with `ReqLLM.model!/1`, which returns an
enriched `%LLMDB.Model{}`.

```elixir
model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Hello world")
```

You can still pass the plain-map model spec directly:

```elixir
ReqLLM.generate_text!(
  %{provider: :openai, id: "gpt-6-mini", base_url: "http://localhost:8000/v1"},
  "Hello world"
)
```

Use additional metadata only when the provider needs it:

```elixir
model =
  ReqLLM.model!(%{
    provider: :google_vertex,
    id: "zai-org/glm-4.7-maas",
    extra: %{family: "glm"}
  })
```

ReqLLM hard-fails early when the model spec is missing required routing data, with
errors aimed at advanced users:

- Inline models always need `provider` and `id` (or `model`)
- Azure still needs a `base_url`
- Google Vertex MaaS models may need `extra.family` when the model family cannot be inferred

## Usage Cost Tracking

Every response includes detailed usage and best-effort cost information calculated from normalized provider usage data plus model pricing metadata:

```elixir
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

response.usage
#=> %{
#     input_tokens: 8,
#     output_tokens: 12,
#     total_tokens: 20,
#     pricing: %{status: :priced, currency: "USD", total: 0.0006},
#     input_cost: 0.00024,
#     output_cost: 0.00036,
#     total_cost: 0.0006
#   }
```

ReqLLM treats pricing as an observability and estimation feature, not an invoice guarantee. Conditional tariffs need caller-confirmed facts in `pricing_context`. If usage or tariff selection is incomplete, `pricing.status` is `:unknown` and numeric cost fields are absent; when the provider returns no usage, `response.usage` may be `nil`. When provider billing accuracy matters, compare these values against your own provider-side reporting. See the [Usage & Billing](guides/usage-and-billing.md) and [Pricing Policy](guides/pricing-policy.md) guides.

### Tool & Image Usage

When using web search or generating images, additional usage metadata is available:

```elixir
# Web search usage (Anthropic, OpenAI, xAI, Google)
{:ok, response} = ReqLLM.generate_text(model, prompt,
  provider_options: [web_search: %{max_uses: 5}])

response.usage.tool_usage
#=> %{web_search: %{count: 2, unit: "call"}}

response.usage.cost
#=> %{tokens: 0.001, tools: 0.02, images: 0.0, total: 0.021}

# Image generation usage
{:ok, response} = ReqLLM.generate_image("openai:gpt-image-1.5", prompt)

response.usage.image_usage
#=> %{generated: %{count: 1, size_class: "1024x1024"}}
```

A native ReqLLM telemetry surface is published for every request, including streaming:

- `[:req_llm, :request, :start | :stop | :exception]` for lifecycle timing, summaries, and usage
- `[:req_llm, :reasoning, :start | :update | :stop]` for standardized thinking and reasoning milestones
- `[:req_llm, :token_usage]` for backwards-compatible token and cost measurements

All events share a `request_id` so you can correlate request lifecycle, reasoning lifecycle, and billing data across providers.

For OpenTelemetry, attach `ReqLLM.OpenTelemetry` once to emit GenAI client spans, optional GenAI metrics, cost attributes, and Langfuse-friendly message capture.

```elixir
ReqLLM.OpenTelemetry.attach("req-llm-otel", content: :attributes, langfuse: true)
```

See `examples/scripts/usage_cost_search_image.exs` and run it from `examples/` with `mix run scripts/usage_cost_search_image.exs` for a multi-provider smoke test that validates search tool and image generation cost metadata. For comprehensive documentation, see the [Telemetry Guide](guides/telemetry.md) and [Usage & Billing Guide](guides/usage-and-billing.md).

## Streaming Configuration

ReqLLM uses Finch for streaming connections with automatic connection pooling. By default, we use HTTP/1-only pools to avoid a known Finch mixed-protocol ALPN bug with large request bodies:

```elixir
# Default configuration (automatic)
config :req_llm,
  stream_pool_timeout: 120_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 8
```

### HTTP/2 Configuration (Advanced)

**Important:** Due to [Finch issue #265](https://github.com/sneako/finch/issues/265), mixed HTTP/1+HTTP/2 ALPN pools may fail when sending request bodies larger than 64KB (large prompts, extensive context windows). This is a bug in Finch's mixed-protocol flow control path, not a limitation of HTTP/2 itself.

If you know all target providers support HTTP/2, you can configure HTTP/2-only pools:

```elixir
# HTTP/2-only configuration
config :req_llm,
  stream_pool_protocols: [:http2],
  stream_pool_count: 8
```

**ReqLLM will error with a helpful message if you try to send a large request body with mixed HTTP/1+HTTP/2 pools.** The error will reference this section for configuration guidance.

Streaming responses hold a connection until completion. For high-scale deployments, tune both the Finch pool capacity and the stream checkout timeout:

```elixir
# High-scale configuration
# config/runtime.exs
round_robin = Finch.Pool.Strategy.RoundRobin.new()

config :req_llm,
  stream_pool_timeout: 300_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 32,
  stream_pool_strategy: {Finch.Pool.Strategy.RoundRobin, round_robin}
```

With the default HTTP/1 transport, concurrent streams per origin are roughly `stream_pool_size * stream_pool_count`. Prefer increasing `stream_pool_count` first when a single pool worker is under pressure; increase `stream_pool_size` when each worker should hold more concurrent HTTP/1 connections. For high worker counts, a round-robin `stream_pool_strategy` spreads stream starts more evenly than Finch's default random selection. These settings configure ReqLLM's default Finch pool; an explicit `finch: [pools: ...]` configuration takes precedence.

If you need origin-specific pools, HTTP/2, connection options, or pool metrics, configure Finch directly:

```elixir
# Advanced Finch configuration
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 32]
    }
  ]
```

Use `pool_timeout: ...` on an individual `stream_text/3` or `stream_object/4` call when one workload needs a longer connection checkout window than the global `stream_pool_timeout` setting.

Advanced users can specify custom Finch instances per request:

```elixir
{:ok, response} = ReqLLM.stream_text(model, messages, finch_name: MyApp.CustomFinch)
```

### StreamResponse Usage Patterns

The new `StreamResponse` provides flexible access patterns:

```elixir
# Real-time streaming for UI
{:ok, response} = ReqLLM.stream_text(model, "Tell me a story")

ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&broadcast_to_liveview/1)
|> Stream.run()

# Concurrent metadata collection (non-blocking)
Task.start(fn ->
  usage = ReqLLM.StreamResponse.usage(response)
  log_usage(usage)
end)

# Simple text collection
text = ReqLLM.StreamResponse.text(response)

# Backward compatibility with legacy Response
{:ok, legacy_response} = ReqLLM.StreamResponse.to_response(response)
```

## Adding a Provider

Choose the integration path from the API behavior:

- Add a dedicated provider module when the API needs special authentication,
  headers, routes, options, request encoding, or response decoding.
- Use the shared catalog gateway when the API uses plain OpenAI Chat
  Completions with bearer authentication and LLMDB has a complete execution
  contract.
- Add a dedicated module for a local runtime when ReqLLM must handle local
  model IDs, optional authentication, or runtime-specific options.

Dedicated modules implement the `ReqLLM.Provider` behavior. LLMDB owns shared
provider and model metadata for both paths.

See the [Adding a Provider Guide](guides/adding_a_provider.md) for detailed implementation instructions.

## Advanced Req Plugin API

For advanced non-streaming use cases, you can use ReqLLM providers directly as Req plugins. This is the canonical implementation used by `ReqLLM.generate_text/3`:

```elixir
# The canonical pattern from ReqLLM.Generation.generate_text/3
with {:ok, model} <- ReqLLM.model("anthropic:claude-haiku-4-5"), # Parse model spec
     {:ok, provider_module} <- ReqLLM.provider(model.provider),        # Get provider module
     {:ok, request} <- provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7), # Build Req request
     {:ok, %Req.Response{body: response}} <- Req.request(request) do   # Execute HTTP request
  {:ok, response}
end

# Customize the Req pipeline with additional headers or middleware
{:ok, model} = ReqLLM.model("anthropic:claude-haiku-4-5")
{:ok, provider_module} = ReqLLM.provider(model.provider)
{:ok, request} = provider_module.prepare_request(:chat, model, "Hello!", temperature: 0.7)

# Add custom headers or middleware before sending
custom_request =
  request
  |> Req.Request.put_header("x-request-id", "my-custom-id")
  |> Req.Request.put_header("x-source", "my-app")

{:ok, response} = Req.request(custom_request)
```

This approach gives you full control over the Req pipeline, allowing you to add custom middleware, modify requests, or integrate with existing Req-based applications. Streaming uses Finch through `stream_text/3`.

## Documentation

- [Compatibility Policy](COMPATIBILITY.md) – stable, experimental, deprecated, platform, and ReqLLM/Jido contracts
- [Model Support Evidence](guides/model-support.md) – generated, surface-specific compatibility tiers
- [Getting Started](guides/getting-started.md) – first call and basic concepts
- [Configuration](guides/configuration.md) – timeouts, connection pools, and global settings
- [Telemetry](guides/telemetry.md) – request lifecycle, reasoning lifecycle, payload capture
- [Core Concepts](guides/core-concepts.md) – architecture & data model
- [Data Structures](guides/data-structures.md) – detailed type information
- [Host Integration](guides/host-integration.md) – stable one-call boundary for Jido and other hosts
- [Provider-native Integrations](guides/provider-native-integrations.md) – MCP, native tool, resource, and future operation boundaries
- [Pricing Policy](guides/pricing-policy.md) – cost-calculation scope, guarantees, and known gaps
- [Usage & Billing](guides/usage-and-billing.md) – token costs, tool usage, image costs
- [Image Generation](guides/image-generation.md) – generating images with OpenAI, Azure, Google, and xAI
- [Mix Tasks](guides/mix-tasks.md) – model sync, compatibility testing, code generation
- [Fixture Testing](guides/fixture-testing.md) – model validation and supported models
- [Adding a Provider](guides/adding_a_provider.md) – extend with new providers
- Provider Guides: [Amazon Bedrock](guides/amazon_bedrock.md), [Anthropic](guides/anthropic.md), [Azure](guides/azure.md), [Cerebras](guides/cerebras.md), [DeepSeek](guides/deepseek.md), [Fireworks AI](guides/fireworks_ai.md), [GitHub Copilot](guides/github_copilot.md), [Google](guides/google.md), [Google Vertex](guides/google_vertex.md), [Groq](guides/groq.md), [Inference.net](guides/inference.md), [LM Studio](guides/lmstudio.md), [Meta](guides/meta.md), [Moonshot AI](guides/moonshot_ai.md), [NEAR AI](guides/nearai.md), [Ollama](guides/ollama.md), [OpenAI](guides/openai.md), [OpenRouter](guides/openrouter.md), [Reflection AI](guides/reflection.md), [StepFun](guides/stepfun.md), [xAI](guides/xai.md), [Z.AI](guides/zai.md), [Z.AI Coder](guides/zai_coder.md), [Zenmux](guides/zenmux.md)

## Roadmap & Status

ReqLLM has reached v1.0.0. Its [compatibility policy](COMPATIBILITY.md)
protects the stable core API while the library continues to improve.
If you run into anything or have suggestions, please open an issue or PR.

### Test Coverage & Quality Commitment

ReqLLM tracks support evidence for **600+ models** across text, streaming, tool
calling, structured output, embeddings, image generation, speech,
transcription, rerank, and OCR. This count is from the October 9, 2026 evidence
snapshot.

Catalog support and fixture-verified coverage are tracked separately on purpose:
provider catalogs move quickly, account access varies, and some modalities need
specialized tests. See [Model Support Evidence](guides/model-support.md) for the
dated status of each exact model and operation. You can also use
`mix req_llm.model_support` or `mix mc "*:*"` to inspect current evidence.

**We welcome bug reports and feedback!** If you encounter issues with any supported model, please open a GitHub issue with details. The more feedback we receive, the stronger the code will be!

## Development

```bash
# Install dependencies
mix deps.get

# Run tests with cached fixtures
mix test

# Run quality checks
mix quality  # format, compile, credo --strict, dialyzer

# Generate HTML and Markdown documentation
mix docs
```

Documentation is generated in `doc/`, including Markdown pages and `llms.txt`.

### Testing with Fixtures

Tests use cached JSON fixtures by default. To regenerate fixtures against live APIs (optional):

```bash
# Regenerate all fixtures
LIVE=true mix test

# Regenerate specific provider fixtures using test tags
LIVE=true mix test --only "provider:anthropic"
```

## Contributing

Provider APIs change continuously. Models, wire formats, and edge cases can
shift without notice, so ReqLLM depends on builders who find those changes in
real applications. Bug reports and patches are welcome, even when the first
version is small or unpolished. Maintainers can help refine the implementation.

When a change fixes provider behavior, include a focused regression test. If
provider access permits, record the smallest live API fixture that proves the
behavior. ReqLLM can then replay that real response without credentials and
keep the edge case covered.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:

- Core library contributions
- Adding dedicated provider modules or shared catalog gateway support
- Extending provider features
- Testing requirements and fixture generation
- Code quality standards

Quick start:

1. Fork the repository
2. Create a feature branch
3. Add a focused test that reproduces the behavior
4. Record a live fixture for provider API changes
5. Run the relevant tests and `mix quality`
6. Submit a pull request

## License

Copyright 2025 Mike Hostetler

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
