# Model Specs

Model specs are how ReqLLM knows which model to call and what metadata is needed to route the request correctly.

That can be as simple as a registry lookup like `"openai:gpt-4o"`, or as explicit as a full `%LLMDB.Model{}` that carries the provider, model ID, base URL, and any extra routing metadata needed for a model that is not in the registry yet.

This guide covers both paths.

## Start with LLMDB

ReqLLM uses [`llm_db`](https://hex.pm/packages/llm_db) as its model registry. The easiest human-readable reference for that registry is [LLMDB.xyz](https://llmdb.xyz).

Use [LLMDB.xyz](https://llmdb.xyz) when you want to:

- look up the exact provider and model ID to pass to ReqLLM
- inspect current model variants and versioned releases
- confirm whether a date-stamped release ID already exists in the registry
- copy an exact `provider:model` spec instead of guessing

ReqLLM and LLMDB intentionally lean into exact, versioned model IDs when providers publish them. That is why you will often see date-based or version-stamped IDs such as:

- `anthropic:claude-3-5-sonnet-20240620`
- `openai:gpt-4o-mini-2024-07-18`
- `google_vertex:claude-sonnet-4-5@20250929`

That strategy matters for developer experience:

- exact IDs are reproducible and easier to debug
- aliases can still resolve to a current canonical model through LLMDB
- moving from one dated release to another is an explicit choice instead of an accidental drift

If the model is already on [LLMDB.xyz](https://llmdb.xyz), prefer using that exact spec first.

## What A Model Spec Is

A model spec is the complete input ReqLLM uses to resolve a model.

In practice, ReqLLM supports four forms:

### 1. String Specs

The most common path. Strings resolve through LLMDB.

```elixir
"anthropic:claude-haiku-4-5"
"openai:gpt-4o-mini-2024-07-18"
"google_vertex:claude-sonnet-4-5@20250929"
```

### 2. Tuple Specs

Tuples also resolve through LLMDB, but let you keep the provider and model ID split.

```elixir
{:anthropic, "claude-haiku-4-5", max_tokens: 512}
{:openai, id: "gpt-4o"}
```

### 3. `%LLMDB.Model{}`

This is the canonical explicit model contract in ReqLLM.

If you already have a `%LLMDB.Model{}`, ReqLLM uses it directly instead of looking up the model in the registry.

```elixir
model =
  LLMDB.Model.new!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Hello")
```

### 4. Plain Maps

ReqLLM accepts plain maps for backwards compatibility and convenience.

They are treated as full model specs and normalized into an enriched `%LLMDB.Model{}`.

```elixir
ReqLLM.generate_text!(
  %{provider: :openai, id: "gpt-6-mini", base_url: "http://localhost:8000/v1"},
  "Hello"
)
```

The clearer path is to normalize first with `ReqLLM.model!/1`.

## How ReqLLM Resolves Model Specs

ReqLLM has two distinct resolution paths:

### Registry Path

Strings and tuples resolve through LLMDB.

```elixir
{:ok, model} = ReqLLM.model("openai:gpt-4o")
{:ok, model} = ReqLLM.model({:anthropic, "claude-haiku-4-5"})
```

This path is best when:

- the model already exists in LLMDB
- you want aliases and canonical version resolution
- you want shared metadata like pricing, capabilities, and limits

### Full Model Specification Path

`%LLMDB.Model{}` values and plain maps bypass registry lookup. They are self-contained model specs.

This path is best when:

- a new model exists but is not in LLMDB yet
- you are testing a local or proxied deployment
- you need per-model `base_url` metadata
- you are working with a private or experimental model ID

This is the key point: you do not need the model to exist in LLMDB before ReqLLM can use it, as long as you provide a complete enough model spec.

## Recommended Workflow

### Use a string when the model is in LLMDB

```elixir
ReqLLM.generate_text!("openai:gpt-4o", "Hello")
```

### Pin an exact release when reproducibility matters

```elixir
ReqLLM.generate_text!("anthropic:claude-3-5-sonnet-20240620", "Hello")
```

### Use `ReqLLM.model!/1` when the model is not in LLMDB yet

```elixir
model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Hello")
```

### Keep the resulting `%LLMDB.Model{}` if you are going to reuse it

```elixir
model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Write a haiku")
ReqLLM.stream_text!(model, "Write a poem")
```

## Minimum Required Fields

For the full model specification path, the minimum required fields are:

- `provider`
- `id` or `model`

ReqLLM then enriches and normalizes the spec where possible.

## Common Fields

These are the fields you will use most often when building a full model spec.

### `provider`

The provider atom, such as `:openai`, `:anthropic`, `:google`, `:google_vertex`, `:azure`, or `:openrouter`.

This is required.

### `id`

The ReqLLM model ID.

For most cases this is also the API model ID. This is required unless you provide `model` instead.

### `model`

An alternate way to provide the model ID. ReqLLM normalizes `id` and `model` so either can seed the spec.

### `provider_model_id`

The provider-facing model ID when it should differ from `id`.

This is useful when:

- you want a friendlier local `id`
- you want to preserve an alias in `id` but send a different provider model ID
- a provider needs a specific wire ID that differs from your local identifier

If it can be derived, ReqLLM and LLMDB will fill it in for you.

### `base_url`

Per-model endpoint metadata.

This is especially useful for:

- local OpenAI-compatible servers
- proxies
- Azure resource endpoints
- provider-compatible gateways

### `capabilities`, `limits`, `modalities`, `pricing`, `cost`

Optional metadata that can improve validation, usage reporting, and capability checks.

You do not need to provide all of these just to make a request.

### `extra`

Provider-specific metadata that does not belong in the common top-level fields.

The main advanced cases today are:

- `extra.family` for certain Google Vertex MaaS models
- `extra.wire.protocol` when you need to force a specific OpenAI-compatible wire protocol

## Examples

### Standard Catalog Model

```elixir
ReqLLM.generate_text!("openai:gpt-4o", "Hello")
```

### Exact Dated Release

```elixir
ReqLLM.generate_text!("openai:gpt-4o-mini-2024-07-18", "Hello")
```

### Local OpenAI-Compatible Server

```elixir
model =
  ReqLLM.model!(%{
    provider: :openai,
    id: "qwen3-32b",
    base_url: "http://localhost:8000/v1"
  })

ReqLLM.generate_text!(model, "Explain supervision trees")
```

### Azure

Azure often benefits from the full model specification path because the Azure resource URL is model metadata.

`deployment` is still a request option.

```elixir
model =
  ReqLLM.model!(%{
    provider: :azure,
    id: "gpt-4o",
    base_url: "https://my-resource.openai.azure.com/openai"
  })

ReqLLM.generate_text!(
  model,
  "Hello",
  deployment: "my-gpt4-deployment"
)
```

### Google Vertex MaaS

Some Google Vertex MaaS and OpenAI-compatible model IDs need an explicit family hint if the family cannot be inferred from the ID alone.

```elixir
model =
  ReqLLM.model!(%{
    provider: :google_vertex,
    id: "zai-org/glm-4.7-maas",
    extra: %{family: "glm"}
  })

ReqLLM.generate_text!(model, "Hello")
```

## Advanced: Local `%LLMDB.Model{}`

The canonical advanced path is an explicit `%LLMDB.Model{}`.

If you want full control, build it directly with `LLMDB.Model.new!/1`.

```elixir
model =
  LLMDB.Model.new!(%{
    provider: :openai,
    id: "gpt-6-mini",
    provider_model_id: "gpt-6-mini",
    base_url: "http://localhost:8000/v1",
    capabilities: %{chat: true},
    limits: %{context: 200_000, output: 8_192}
  })

ReqLLM.generate_text!(model, "Hello")
```

This is useful when:

- you want to construct and store reusable model definitions yourself
- you want a fully explicit contract with no ambiguity about the final struct
- you are integrating ReqLLM into a system that already manages model metadata

Plain maps are still accepted, but conceptually they are convenience input for constructing `%LLMDB.Model{}` values.

## Validation And Errors

ReqLLM intentionally hard-fails early for malformed full model specs.

Common failures include:

- missing `provider`
- missing `id` or `model`
- provider string that does not correspond to a registered provider
- provider-specific routing metadata that cannot be inferred

Provider-specific examples:

- Azure still needs `base_url`
- Google Vertex MaaS models may need `extra.family`

This is an advanced workflow, so explicit errors are preferred over silent fallback behavior.

## Useful Helpers

### Resolve a model spec

```elixir
{:ok, model} = ReqLLM.model("openai:gpt-4o")
model = ReqLLM.model!(%{provider: :openai, id: "gpt-6-mini"})
```

### Browse models in the registry

```elixir
models = LLMDB.models(:openai)
specs = Enum.map(models, &LLMDB.Model.spec/1)
```

### Resolve directly through LLMDB

```elixir
{:ok, model} = LLMDB.model("openai:gpt-4o")
```

## When To Update LLMDB Instead

The full model specification path is the fastest way to use a model that is missing from the registry.

You should still update LLMDB or add registry metadata when you want:

- the model to be discoverable on [LLMDB.xyz](https://llmdb.xyz)
- shared, reusable metadata for the team
- compatibility tooling such as `mix mc`
- richer cost, capability, and limit metadata everywhere

Use the registry for shared catalog quality.

Use full model specs when you need to move immediately.
