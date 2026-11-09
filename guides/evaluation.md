# Evaluation providers and gateways

`ReqLLM.evaluate/4` answers named questions without falling back to chat.
`ReqLLM.evaluation_models/0` lists models with both an explicit evaluation
execution contract and an available compatible adapter. Discovery does not
require credentials or make an HTTP request.

## Execution metadata

LLMDB already supports evaluation metadata. For example, an overlay can describe
an executable gateway provider with this runtime metadata:

```elixir
LLMDB.Provider.new!(%{
  id: :my_gateway,
  name: "My gateway",
  catalog_only: false,
  runtime: %{
    base_url: "https://gateway.example/v1",
    auth: %{type: "bearer", env: ["MY_GATEWAY_API_KEY"]}
  }
})
```

An evaluation model for that provider can use:

```elixir
model = ReqLLM.model!(%{
  provider: :my_gateway,
  id: "ticket-evaluator",
  catalog_only: false,
  capabilities: %{evaluate: true, chat: false},
  execution: %{
    evaluate: %{
      supported: true,
      family: "openrouter_decisions",
      wire_protocol: "openrouter_decisions",
      transport: "http",
      base_url: "https://gateway.example",
      path: "/v1/custom/decisions",
      provider_model_id: "upstream-evaluator"
    }
  }
})

ReqLLM.evaluate(model, %{ticket: "Refund me"}, %{
  urgent: %{type: :boolean, instructions: "Is this urgent?"}
}, api_key: "gateway-key")
```

The provider runtime must be installed in the application's LLMDB catalog or
overlay. A full inline model does not create provider runtime metadata. Inline
maps and `%LLMDB.Model{}` specs remain supported for unlisted models. Catalog
models always use canonical catalog metadata, and inline specs cannot bypass
catalog filters. Inline models are not added to discovery automatically.

Supported family/wire-protocol pairs are:

- `typesafe_systemone` / `typesafe_systemone`
- `openrouter_decisions` / `openrouter_decisions`
- `openai_decisions` / `openai_decisions`

The first two protocols accept text or JSON state and share question/answer
normalization. OpenAI Decisions also accepts `ReqLLM.Context`, including supported
images in user messages, and validates ordered answers against the request.
Protocol support is independent of the provider name. Alternative answer
probabilities and fractional scores are retained.

The shared catalog gateway requires an executable provider and model, HTTP(S)
transport, a valid base URL and path, and plain bearer authentication. Additional
runtime headers, default query parameters, and other authentication schemes
require a dedicated provider adapter. Unsupported contracts fail before HTTP;
there is no direct-provider or chat fallback.

## Registered evaluation adapters

A registered provider must explicitly declare its implemented protocols:

```elixir
defmodule MyEvaluator do
  use ReqLLM.Provider,
    id: :my_gateway,
    default_base_url: "https://gateway.example"

  @impl ReqLLM.Provider
  def evaluation_protocols, do: ["openrouter_decisions"]

  @impl ReqLLM.Provider
  def prepare_request(:evaluate, model, input, opts) do
    ReqLLM.Providers.CatalogGateway.prepare_request(:evaluate, model, input, opts)
  end
end
```

This delegation reuses the shared transport and codecs and requires the same
LLMDB runtime metadata as the catalog gateway. An adapter with custom
authentication can instead build its own Req pipeline and reuse the appropriate
decision codec. Register it with `ReqLLM.Providers.register!/1` or the application's
`config :req_llm, :custom_providers` list.

Registration or a generic `prepare_request/4` callback alone does not enable
evaluation. A registered adapter takes priority and must declare compatibility;
an incompatible registered adapter does not silently use the catalog gateway.

## Endpoints, credentials, and identity

For gateway requests, base URL precedence is the explicit `:base_url` option,
`execution.evaluate.base_url`, model `base_url`, then provider runtime `base_url`.
The `:evaluate_path` option overrides `execution.evaluate.path`. Built-in adapters
also honor evaluation endpoint metadata and these explicit overrides, retaining
their provider-specific credential handling.

URL joining preserves custom prefixes. A path already beginning with the full
base path is not prefixed again; a matching terminal API version segment, such
as `/v1`, is not doubled. Thus both a root URL with `/v1/decisions` and a `/v1`
base URL with `/decisions` reach the same endpoint.

The evaluation contract's `provider_model_id` is the wire model. System One can
fall back to the model's provider model ID or ID when the contract omits it.
The dedicated Azure adapter retains its deployment semantics: use
`provider_options: [azure: [deployment: "your-deployment"]]` to choose the request
model; otherwise it defaults to the model ID as before.

The configured gateway identity remains the provider used for credentials,
telemetry, and response metadata. Bearer credential precedence is `:api_key`,
the gateway's ReqLLM API-key configuration, then its runtime `auth.env` names.
Selecting an OpenAI or OpenRouter protocol never selects their API keys or hosts.
The existing retries, total timeout, usage, and `ReqLLM.Response` contracts apply.

An execution contract describes client compatibility, not proof that a deployed
gateway serves the endpoint. Confirm its route, authentication, request schema,
and response schema separately before integration testing.
