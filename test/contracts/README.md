# V1 contract test inventory

This inventory maps the compatibility policy to focused tests already present in
the suite. Tests tagged `contract: :public_api` protect the stable facade and
value contracts. Tests tagged `contract: :provider_extension` protect the
third-party provider boundary.

Run the focused suites with:

```sh
mix test --only "contract:public_api"
mix test --only "contract:provider_extension"
```

## Stable public contracts

| Contract | Primary evidence |
| --- | --- |
| Model strings, tuples, plain maps, and `%LLMDB.Model{}` values | `test/req_llm_test.exs`, `test/req_llm/model_operation_test.exs` |
| Text generation, streaming, and structured output tuples and bang helpers | `test/req_llm/generation_test.exs` |
| Embedding, image, transcription, speech, reranking, and OCR facades | Corresponding operation tests under `test/req_llm/` |
| Public errors and directly documented key/configuration behavior | `test/req_llm/error_test.exs`, `test/req_llm/keys_test.exs`, `test/req_llm/auth_test.exs` |
| Context, message, content part, tool, tool call, tool result, response, stream response, and stream chunk values | Corresponding value tests under `test/req_llm/` |
| Stream enumeration, metadata, materialization, cancellation, and cleanup | `test/req_llm/stream_response_test.exs` and `test/req_llm/response/stream_test.exs` |
| Deprecated streaming bang helpers and their warnings | `test/req_llm_test.exs`, `test/req_llm/generation_test.exs` |

## Stable provider extension contracts

`test/contracts/provider_extension_contract_test.exs` applies the reusable
`ReqLLM.ProviderCase.provider_contract/1` checks to a provider defined outside
the first-party provider namespace. It protects required callbacks,
registration, inline model routing, generated identity and schema helpers, and
the callbacks inherited from `ReqLLM.Provider.Defaults`. A minimal provider
fixture verifies that optional callbacks remain optional.

Existing provider defaults and first-party implementations remain covered by
`test/req_llm/provider/defaults_test.exs`, `test/req_llm/providers_test.exs`, and
the provider tests under `test/providers/`. Live model matrices and recorded
provider responses remain compatibility evidence, but are not duplicated by
this contract suite.

## Intentionally not frozen by this suite

- `ReqLLM.OpenAI.Realtime` is explicitly experimental. Its current session and
  event shapes are not promoted to stable V1 contracts here.
- Venice search-result stream chunks enabled by its explicitly experimental
  provider option are not promoted to stable V1 stream semantics here.
- Private modules, intermediate request maps, and first-party module layout are
  internal implementation details.
- Agent loops, approvals, memory, and workflow orchestration belong to Jido or
  another host and are not ReqLLM API contracts.
