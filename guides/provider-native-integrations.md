# Provider-native integration boundaries

> Status: accepted for ReqLLM 1.x, July 17, 2026

ReqLLM owns one model interaction. It may configure a provider capability,
transport one request or stream, and retain the result in canonical values or
an explicitly provider-scoped view. It does not become the runtime for every
protocol, resource, or action that a model provider can reach.

This guide defines where MCP, provider-executed tools, provider-native
resources, and future operation families belong. It is an architecture
boundary, not a new MCP client, tool runtime, or modality API.

## Integration classes

Similar-looking tool events can require different actions. Classify the
integration before choosing an API:

| Class | Example | Execution owner | ReqLLM result |
| --- | --- | --- | --- |
| Application tool | An Elixir callback described by `ReqLLM.Tool` | Application or Jido, after policy and approval | An actionable `ReqLLM.ToolCall`, followed by an application-supplied result |
| Provider-executed builtin | Provider web search, file search, or code execution | Model provider during the current call | A non-actionable builtin call, usage, sources, and provider items when available |
| Provider-native call requiring a result | A provider-specific call that the host must satisfy | Application, provider adapter, or optional integration | A non-application `ToolCall` that needs an explicitly matched result |
| Provider-owned resource | An uploaded file, container, remote store, or session | Its provider-scoped lifecycle module and the application | A provider-owned reference or provider-native value |
| External protocol integration | An application-side MCP client | Optional package or application | Canonical tool definitions, content, or results only where the mapping is exact |

Canonical projection does not make native behavior portable. It gives callers
a stable place to inspect the overlapping information while retaining the
provider-specific value when semantics differ.

## Ownership matrix

| Layer | Owns | Does not own |
| --- | --- | --- |
| ReqLLM core | One operation; model resolution; canonical messages, application tools, tool calls/results, output projections, usage, warnings, errors, and telemetry | Agent loops, protocol clients, durable resources, approvals, sandboxes, or provider-specific lifecycle policy |
| Provider namespaces | Provider request options, endpoint selection, native event decoding, provider-owned resources, and narrowly scoped lifecycle helpers | Cross-provider orchestration or a claim that native behavior is portable |
| Optional packages | Protocol clients, substantial optional dependencies, independently versioned adapters, and reusable bridges such as an MCP or Jido adapter | Changes to the base provider behaviour or hidden control of later model calls |
| Application | Credentials, tenant policy, allowed tools and resources, data retention, result persistence, and application-specific adapters | Assuming that ReqLLM has approved a tool merely because it decoded one |
| Jido or another host | Approvals, execution policy, loops, step limits, cross-call retries, memory strategy, durability, delegation, checkpoints, and sandbox orchestration | Provider wire translation or changing ReqLLM's one-call result contract |

The narrowest suitable layer wins. A provider-specific feature starts in its
provider namespace or request options. A protocol with its own connection,
discovery, authentication, and lifecycle belongs in an optional package. Logic
that decides what happens next belongs in the application or Jido.

## Provider-native tools

Provider-trained or provider-hosted tools include search, code execution,
computer use, memory, file search, and similar capabilities. ReqLLM can encode
their provider-specific configuration and decode what happened during one
operation. It does not execute the provider service, emulate it locally, or
promise identical behavior from another provider.

### Provider-executed builtins

For example, OpenAI Responses accepts provider tool maps alongside application
tools:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    "openai:gpt-5-mini",
    "Find the latest ReqLLM release notes.",
    tools: [%{"type" => "web_search"}]
  )

resolutions =
  response
  |> ReqLLM.Response.tool_calls()
  |> Enum.map(&ReqLLM.ToolCall.resolve(&1, []))
```

A decoded builtin resolves with `state: :provider_executed`. The provider has
already performed it, so the host must not execute or replay it as an
application callback. Builtin-only responses classify as `:final_answer` even
though their calls remain visible for observability.

Exact common information uses existing projections:

- `ReqLLM.Response.tool_calls/1` retains observed calls;
- `ReqLLM.Response.sources/1` and `annotations/1` expose retained supporting
  material;
- `ReqLLM.Response.usage/1` exposes normalized usage when reported; and
- `ReqLLM.Response.provider_items/1` exposes native output that has no more
  precise canonical type.

For example, an OpenAI Code Interpreter item can appear in the provider output
channel. Its canonical type is `:provider_item`, not a portable claim that all
providers share OpenAI's container, code, status, or artifact semantics:

```elixir
provider_items = ReqLLM.Response.provider_items(response)
```

Provider metadata remains available for provider-aware consumers. Portable
control flow should use canonical values and documented classifications rather
than branching on undocumented metadata keys.

### Native calls requiring host results

A provider adapter can mark a decoded call as provider-native without making
it an application callback:

```elixir
call =
  "native_1"
  |> ReqLLM.ToolCall.new("provider_search", ~s({"query":"ReqLLM"}))
  |> ReqLLM.ToolCall.put_metadata(%{provider_native: :openai})

resolution = ReqLLM.ToolCall.resolve(call, [])
```

This resolves with `state: :provider_native`. `ReqLLM.ToolCall.execute/3` will
not invoke an application tool for it. If continuation requires a result, the
host obtains that result through the appropriate integration and appends an
explicit, ID-matched tool exchange with
`ReqLLM.Context.append_tool_exchange/3`.

Provider-executed and provider-native are intentionally different:

- `:provider_executed` means the provider already completed the action and no
  local result should be replayed;
- `:provider_native` means the call is not an application callback, but its
  provider contract may require the host to supply a result.

## MCP has two explicit seams

MCP is not a callback on `ReqLLM.Provider` and is not a requirement for adding
a provider. It can enter a ReqLLM application through either of two boundaries.

### Application-side MCP

An application-side MCP client owns connection setup, capability discovery,
protocol negotiation, authentication, reconnects, cancellation, and protocol
errors. That client belongs in an optional package or the application.

An adapter may convert an MCP tool description into `ReqLLM.Tool` when its
name, description, and input schema have an exact representation. The callback
can delegate a single approved invocation to the application's MCP client:

```elixir
{:ok, search_tool} =
  ReqLLM.Tool.new(
    name: "search_docs",
    description: "Search application documentation",
    parameter_schema: [query: [type: :string, required: true]],
    callback: fn %{query: query} -> MyApp.MCP.call_tool("search_docs", %{query: query}) end
  )
```

ReqLLM merely carries that application tool definition into one model call.
The host still resolves the returned call, applies policy, and chooses whether
to invoke the callback. Tool discovery does not authorize execution.

MCP resources can become message content only when the adapter can preserve
their model-visible meaning with an existing `ContentPart`. Otherwise the
optional package or application must transform the resource deliberately or
retain it as protocol-native data. ReqLLM core does not add a generic MCP
resource struct whose fields would imply portability.

### Provider-hosted MCP

Some providers accept a native MCP tool configuration and connect to a remote
server themselves. In that mode a provider-specific tool map or provider option
is transported by the provider adapter, and native calls, approvals, or results
are decoded only to the extent that the provider returns them.

This does not make ReqLLM an MCP client. The model provider, not the ReqLLM
process, owns the protocol connection. Provider-specific configuration and
events remain provider-native; only exact tool, source, usage, or output overlap
is projected canonically.

The two seams must not be hidden behind one generic option. They have different
network paths, credentials, approval mechanisms, failure modes, and data
retention policies.

## Provider-owned resources and sessions

Provider resources belong in a provider namespace when their identifiers,
lifecycle, and guarantees are provider-specific:

| Capability | V1 placement | Reason |
| --- | --- | --- |
| OpenAI file upload, retrieval, listing, and deletion | `ReqLLM.Providers.OpenAI.Files` | The endpoint, purposes, expiry, and deletion behavior are OpenAI-specific |
| A file passed into a model call | `ReqLLM.Message.ContentPart` with optional provider ownership metadata | The content role is common; ownership and lifecycle remain explicit |
| OpenAI Realtime session | `ReqLLM.OpenAI.Realtime` | It is a long-lived provider session, not a `stream_text/3` transport alias |
| Provider container or remote memory ID | Provider options, metadata, or a provider namespace | The resource semantics and lifecycle are not portable |
| Workflow memory | Application or Jido | Selection, retention, retrieval, and use span model calls |

Creating a common content reference does not transfer lifecycle ownership to
ReqLLM core. For example, `ReqLLM.Providers.OpenAI.Files.upload/2` returns an
owned `ContentPart`, while the application still decides retention and deletion.
Regular inspection and telemetry redact owned file identifiers; explicit
reference access remains sensitive.

Realtime follows the same rule. Its projected view maps only exact overlap to
`ReqLLM.StreamEvent` and keeps all other events native. Session hosting,
reconnection, audio devices, protocol-level MCP, and follow-up behavior remain
with the application or Jido.

## Security and credentials

Integration placement is also a trust boundary:

- Provider API credentials are resolved by the provider adapter from the
  documented application or per-call configuration. They must not be copied
  into tool arguments, canonical output, provider metadata, or telemetry.
- Application-side MCP credentials remain with the application or optional MCP
  client. Tool definitions should contain schemas and callbacks, not serialized
  credentials.
- Credentials intentionally forwarded for a provider-hosted integration cross
  into that provider's trust boundary. They remain provider-specific request
  data and must never be presented as a portable ReqLLM option.
- Tool descriptions, arguments, results, remote resources, citations, and
  provider-native events are untrusted input. The host owns validation,
  authorization, tenant isolation, and retention policy.
- A provider label such as "computer use" or "code interpreter" does not prove
  that an action meets an application's sandbox or approval requirements. The
  application or Jido owns those guarantees.
- Raw provider payloads can contain prompts, transcripts, tool arguments,
  results, identifiers, and error details. Use redacted projections by default;
  explicit raw access is for an authorized consumer with its own retention
  policy.

ReqLLM may stop a current request or stream and release its transport. It does
not revoke provider-side effects, close application-owned protocol clients, or
clean up every provider resource created by a native tool. Those lifecycles
must stay visible to their owner.

## Deciding where new capability belongs

Use this sequence for future proposals:

1. If the capability only changes encoding or decoding for one provider, keep
   it in that provider adapter or its options.
2. If it creates or manages a provider-owned resource, use a provider namespace
   with an explicit lifecycle.
3. If it brings an independent protocol, connection lifecycle, or substantial
   optional dependencies, use a separately versioned optional package.
4. If it decides whether to approve, execute, retry, persist, delegate, or make
   another model call, put it in the application or Jido.
5. If several providers expose a genuinely shared one-operation capability,
   consider a new explicit ReqLLM operation rather than disguising it as chat.

A future operation family is justified when it needs a distinct combination of:

- input semantics that cannot be represented honestly as a text/message call;
- a dedicated result type or artifact lifecycle;
- endpoint, polling, cancellation, timeout, or streaming behavior;
- model capability and option validation;
- usage, cost, error, telemetry, and compatibility evidence; and
- a provider-independent contract that does not merely rename one vendor's
  payload.

Video generation is the representative example. If added, it should have an
explicit operation and result contract for generated video artifacts, progress,
usage, cancellation, and provider adaptation. It should not be routed through
`generate_text/3` merely because one provider exposes video as a chat tool.

Conversely, a provider's remote memory identifier does not justify a universal
memory API. It remains provider-scoped until there is a portable one-operation
contract. Durable workflow memory still belongs in Jido or the application
regardless of provider support.

## V1 compatibility result

This decision adds no provider callback, MCP runtime, agent loop, resource
manager, operation entrypoint, or default behavior. Existing application tools,
provider tool maps, `provider_options`, response structs, stream chunks, file
references, and Realtime raw events keep their current contracts.

New provider-native support in V1 must be additive, provider-scoped where
appropriate, explicit about native retention, and backed by compatibility
evidence for the exact surface it changes. A proposal that cannot meet those
constraints waits for V2 or ships as a separately versioned integration.

See the [ReqLLM 1.x compatibility policy](../COMPATIBILITY.md) for the protected
contracts, the [one-call host integration guide](host-integration.md) for the
Jido boundary, the [data structures guide](data-structures.md) for owned file
references, and the [OpenAI guide](openai.md) for current file, Realtime, and
provider-executed tool examples.
