# LM Studio

Run local models through [LM Studio's OpenAI-compatible API](https://lmstudio.ai/docs/developer/openai-compat).
The built-in `:lmstudio` provider supports chat, streaming, tool calling, image
inputs, structured output, and embeddings, subject to the selected model's
capabilities.

## Setup and model selection

1. Install LM Studio and download a model.
2. Start its local API server in the Developer tab, or run `lms server start`.
3. Use an identifier returned by `GET http://127.0.0.1:1234/v1/models`.

Local model names do not need to exist in LLMDB. An explicit model spec avoids
the unverified-model warning associated with uncataloged string specs:

```elixir
model = ReqLLM.model!(%{provider: :lmstudio, id: "my-local-model"})

{:ok, response} = ReqLLM.generate_text(model, "Hello!")
ReqLLM.Response.text(response)
```

Replace `my-local-model` with your server's model identifier. The shorthand
`"lmstudio:my-local-model"` also works. Identifiers containing slashes, colons,
or quantization suffixes are preserved. For an application alias, set
`provider_model_id` on the model spec to the identifier LM Studio expects.

ReqLLM does not discover or download models automatically. Catalog pricing and
capability metadata may be absent for local models. See [Model Specs](model-specs.md)
for supplying metadata explicitly.

## Connection and authentication

The default base URL is `http://127.0.0.1:1234/v1`. Configure another server with:

```elixir
config :req_llm, :lmstudio, base_url: "http://my-server:1234/v1"
```

You can also set `base_url` on a model spec or individual request. Request options
take precedence over the model URL, then provider configuration, then the default.
Include `/v1` in the base URL.

No API key is required by default. If you enable
[LM Studio authentication](https://lmstudio.ai/docs/developer/core/authentication),
provide the server token through one of these sources, in precedence order:

1. The request's `api_key: "..."` option.
2. `config :req_llm, :lmstudio_api_key, "..."`.
3. The `LMSTUDIO_API_KEY` environment variable.

An explicitly empty key is an error. Without a configured key, ReqLLM sends no
authorization header. OpenAI credentials are not used for LM Studio.

Model loading can make the first request slower. Increase the timeout when needed:

```elixir
ReqLLM.generate_text(model, "Hello!", receive_timeout: 120_000)
```

## Streaming

```elixir
{:ok, stream} = ReqLLM.stream_text(model, "Write a short poem.")

stream
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(&IO.write/1)
```

Alternatively, call `ReqLLM.StreamResponse.to_response/1` to collect the complete
response, including usage, reasoning content, and tool calls.

## Structured output

`generate_object/4` and `stream_object/4` use LM Studio's native JSON schema
response format. They do not add a synthetic tool to the prompt.

```elixir
schema = [name: [type: :string, required: true], age: [type: :integer]]

{:ok, response} =
  ReqLLM.generate_object(model, "Alice is 30 years old.", schema)

response.object
```

Both APIs use `response_format.type = "json_schema"`. Actual constraint support
depends on the model and runtime; see
[LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output).

## Tools and images

Pass normal ReqLLM tools through `tools:`. ReqLLM returns tool calls for your
application to execute; append results to the returned context for the next turn:

```elixir
tool = ReqLLM.tool(
  name: "weather",
  description: "Get the weather in a city",
  parameter_schema: [city: [type: :string, required: true]],
  callback: fn _args -> {:ok, "Sunny, 22 Celsius"} end
)

{:ok, response} = ReqLLM.generate_text(model, "Weather in Paris?", tools: [tool])

for call <- ReqLLM.Response.tool_calls(response) do
  ReqLLM.Context.append(
    response.context,
    ReqLLM.Context.tool_result(call.id, "weather", "Sunny, 22 Celsius")
  )
end
```

Tool reliability depends on the model's training and chat template. See
[LM Studio tool use](https://lmstudio.ai/docs/developer/openai-compat/tools).
Vision models accept ReqLLM image content parts in both buffered and streaming
requests; use the normal [content parts API](data-structures.md).

## Embeddings

Select a downloaded embedding model and explicitly declare its capability:

```elixir
embedding_model = ReqLLM.model!(%{
  provider: :lmstudio,
  id: "text-embedding-nomic-embed-text-v1.5",
  capabilities: %{embeddings: true}
})

{:ok, vector} = ReqLLM.embed(embedding_model, "Hello world")
{:ok, vectors} = ReqLLM.embed(embedding_model, ["Hello", "World"])
```

`return_usage: true` also returns server-reported token usage. Some LM Studio
embedding runtimes report zero token counts. The `dimensions` option is forwarded
to the server; support depends on the embedding model and runtime.

## Provider options and reasoning

```elixir
ReqLLM.generate_text(model, "Hello!",
  reasoning_effort: :low,
  provider_options: [ttl: 600, repeat_penalty: 1.1]
)
```

The provider-keyed form `provider_options: [lmstudio: [ttl: 600]]` is also supported.
These provider options apply to chat and structured-output requests.

| Option | Meaning |
| --- | --- |
| `ttl` | Idle time in seconds for a model loaded through just-in-time loading. |
| `repeat_penalty` | Runtime repetition penalty, expressed as a float. |
| `response_format` | Raw OpenAI-compatible response format for chat requests. Object APIs supply their own JSON schema. |

`reasoning_effort` accepts `:none`, `:minimal`, `:low`, `:medium`, `:high`, and
`:xhigh`. `:default` omits the field; ReqLLM's `:max` maps to `:xhigh` with a
warning. Chat Completions reasoning controls require
[LM Studio 0.4.8 or newer](https://lmstudio.ai/changelog/lmstudio/lmstudio-v0.4.8).
Models and runtimes may interpret or ignore these levels differently; `:none`
does not guarantee that every model disables thinking. Returned `reasoning` and
`reasoning_content` fields use ReqLLM's normal thinking content representation.

## Scope and differences from Ollama

This provider covers ReqLLM's inference APIs through `/v1/chat/completions` and
`/v1/embeddings`. Configure context length, GPU offload, and model loading in
LM Studio. Ollama's `num_ctx` and `keep_alive` options are not translated.
LM Studio's [TTL and auto-eviction](https://lmstudio.ai/docs/developer/core/ttl-and-auto-evict)
have different semantics; `ttl` is not an immediate unload command.

Model management, downloads, the native stateful chat API, Responses API, and
server-side MCP integrations are outside this provider's scope.

## Testing

Transport tests use a local HTTP stub and need no LM Studio installation:

```bash
mix test test/providers/lmstudio_test.exs
```

Recorded coverage uses explicit local model specs, independently of LLMDB and
the catalog-based `mix mc` model selection:

```bash
mix test test/coverage/lmstudio/inference_test.exs --include coverage
```

The suites also support provider, category, model, and scenario filters:

```bash
mix test --only provider:lmstudio
mix test test/coverage/lmstudio/inference_test.exs --only category:embedding
mix test test/coverage/lmstudio/inference_test.exs --only scenario:object_streaming
mix test test/coverage/lmstudio/inference_test.exs --only model:qwen2.5-0.5b-instruct
```

To re-record, run LM Studio with the model IDs declared in that test available,
then use:

```bash
REQ_LLM_FIXTURES_MODE=record mix test test/coverage/lmstudio/inference_test.exs --include coverage
```

Configure a different recording server with the provider's `base_url` setting.
Cached replay does not require a running server or downloaded models. The recorded
suite covers chat, streaming, tool round trips, streamed tools, vision, structured
output (buffered and streamed), and single and batch embeddings. Structured-output
recordings use the non-reasoning `qwen2.5-0.5b-instruct` model.

During live verification with `qwen3.8-27b-mlx`, LM Studio returned constrained
JSON in `reasoning_content` with an empty answer, even with
`reasoning_effort: :none`. That model/runtime combination did not produce a usable structured
object. ReqLLM keeps reasoning separate from answer content; use a model/runtime
that returns constrained JSON in the answer when relying on structured output.
