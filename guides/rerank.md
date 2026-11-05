# Reranking

ReqLLM uses one response type for Cohere rerank calls and compatible APIs.
`ReqLLM.rerank/2` returns a `ReqLLM.RerankResponse` with the original document,
its input index, and its relevance score.

## Cohere

Set `COHERE_API_KEY`, and use a Cohere rerank model:

```elixir
{:ok, response} =
  ReqLLM.rerank("cohere:rerank-v3.5",
    query: "How do I renew a passport?",
    documents: [
      "Renew a passport at city hall.",
      "Submit a tax return online."
    ],
    top_n: 1
  )
```

Cohere keeps its default `/v2/rerank` path.

## Albert API

Albert API uses the Cohere-compatible request and response format at
`POST /v1/rerank`. Set `ALBERT_API_KEY`, and use the Albert model identity:

```elixir
{:ok, response} =
  ReqLLM.rerank("albert:openweight-rerank",
    query: "Comment renouveler mon passeport ?",
    documents: [
      "Le renouvellement du passeport se fait en mairie.",
      "La déclaration de revenus se fait en ligne."
    ],
    top_n: 1
  )
```

LLMDB supplies the `execution.rerank` contract. ReqLLM uses that contract to
select the Cohere-compatible body format and the Albert `/v1/rerank` path. The
provider stays `:albert`, so ReqLLM uses `ALBERT_API_KEY` and reports Albert in
telemetry.

The supported shared contract is:

```elixir
%{
  supported: true,
  family: "cohere_rerank_compatible",
  wire_protocol: "cohere_rerank",
  base_url: "https://api.albert.etalab.gouv.fr",
  path: "/v1/rerank"
}
```

A registered provider module has priority over shared execution metadata.
Missing or unsupported rerank metadata returns an error before ReqLLM sends a
request.

## Local Cohere-Compatible Server

Use `:base_url` and `:rerank_path` to point the Cohere adapter at a local server:

```elixir
{:ok, response} =
  ReqLLM.rerank("cohere:rerank-v3.5",
    query: "rank these documents",
    documents: ["first", "second"],
    base_url: "http://localhost:8000",
    rerank_path: "/v1/rerank",
    api_key: "local-key"
  )
```

Explicit `:base_url` and `:rerank_path` values take priority over catalog
metadata. Request text, documents, credentials, and per-request options are not
stored in LLMDB.
