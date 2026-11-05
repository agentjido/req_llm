# Superlinked Inference Engine

Use Superlinked Inference Engine (SIE) through its hosted, local, or cluster
API. ReqLLM supports these SIE routes:

- OpenAI-compatible chat, streaming, tools, and dense embeddings under `/v1`.
- Native reranking at `/v1/score/{model}`.

Set the hosted-service key before you make a request:

```bash
export SIE_API_KEY="your-key"
```

You can also pass `api_key:` to one request or set
`config :req_llm, :superlinked_api_key, "your-key"`. ReqLLM sends the key as a
bearer token.

## Chat and streaming

Select a chat model from the [Superlinked console](https://console.superlinked.com/console):

```elixir
model = "superlinked:Qwen/Qwen3.5-4B"

{:ok, response} = ReqLLM.generate_text(model, "Explain vector search in one sentence.")
ReqLLM.Response.text(response)
```

The normal ReqLLM tool option uses the SIE OpenAI-compatible tool shape:

```elixir
tool =
  ReqLLM.tool(
    name: "lookup",
    description: "Look up one item",
    parameter_schema: [id: [type: :string, required: true]],
    callback: fn %{"id" => id} -> {:ok, "Item #{id}"} end
  )

{:ok, response} = ReqLLM.generate_text(model, "Look up item 42.", tools: [tool])
```

For streaming:

```elixir
{:ok, stream} = ReqLLM.stream_text(model, "Write one short sentence.")

stream
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(&IO.write/1)
```

## Dense embeddings

```elixir
{:ok, vector} =
  ReqLLM.embed(
    "superlinked:Qwen/Qwen3-Embedding-4B",
    "A document to embed"
  )
```

The selected model controls the vector dimensions. ReqLLM does not map SIE
native sparse or multivector embedding endpoints to `ReqLLM.embed/3`.

## Reranking

```elixir
{:ok, response} =
  ReqLLM.rerank(
    "superlinked:Qwen/Qwen3-Reranker-0.6B",
    query: "best city for art",
    documents: ["Paris has many museums.", "Berlin has many galleries."],
    top_n: 1
  )

response.results
```

ReqLLM maps its rerank request to the native SIE score route and converts the
result to `ReqLLM.RerankResponse`. SIE does not accept the Cohere
`max_tokens_per_doc` or `priority` fields on this route. ReqLLM applies `top_n`
after it receives the scores.

## Local and cluster endpoints

Pass a base URL that ends in `/v1`:

```elixir
ReqLLM.generate_text(model, "Hello",
  base_url: "http://sie.internal:8080/v1",
  api_key: "cluster-key"
)
```

ReqLLM uses that `/v1` base for chat and embeddings. It appends
`/score/{model}` to the same base for reranking.

You can use an inline model when a local model is not in LLMDB:

```elixir
model =
  ReqLLM.model!(%{
    provider: :superlinked,
    id: "my-chat-model",
    capabilities: %{chat: true, tools: %{enabled: true}}
  })
```

## Provisioning retries

SIE can return `503 PROVISIONING` with a `Retry-After` header while it starts a
model. ReqLLM follows that header and applies its bounded retry policy. Increase
the limits for deployments that have a long cold start:

```elixir
ReqLLM.generate_text(model, "Hello",
  max_retries: 8,
  receive_timeout: 120_000,
  total_timeout: 600_000
)
```

The total timeout includes all retry waits. A request stops when it reaches
`max_retries` or `total_timeout`.

## Scope

This provider does not claim support for SIE native sparse embeddings,
multivector embeddings, extraction, or OCR. Those APIs do not use the OpenAI or
Cohere wire formats that this provider implements.

Offline provider tests use local HTTP stubs and do not need a live key:

```bash
mix test test/req_llm/providers/superlinked_test.exs
```
