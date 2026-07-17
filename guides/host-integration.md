# One-call host integration

ReqLLM owns one model interaction. A host such as Jido owns everything that
happens between interactions: policy, approvals, tool execution, persistence,
loop termination, retries of completed steps, and the decision to call a model
again.

This guide describes the stable V1 boundary for that integration. It uses the
same public API as an application calling ReqLLM directly; there is no parallel
host facade or agent runtime.

## The boundary

| Phase | ReqLLM provides | The host owns |
| --- | --- | --- |
| Resolve | `ReqLLM.model/1` and an `%LLMDB.Model{}` | Model selection policy |
| Invoke | One `ReqLLM.generate_text/3` or `ReqLLM.stream_text/3` operation | When and whether to invoke it |
| Consume | `ReqLLM.Response`, `ReqLLM.StreamResponse`, and `ReqLLM.StreamEvent` | UI updates and application state |
| Inspect | Normalized output, tool calls, usage, warnings, finish reasons, and errors | Approval and execution policy |
| Continue | Canonical tool-result messages and `ReqLLM.Context.append_tool_exchange/3` | Tool results and any later invocation |
| Observe | A ReqLLM `request_id` and caller-provided `conversation_id` | Workflow, tenant, trace, and step correlation |

Keep control flow on canonical values and projections:

- `ReqLLM.Response.classify/1` distinguishes a final answer from actionable
  tool calls.
- `ReqLLM.Response.tool_calls/1`, `usage/1`, `output_items/1`, and
  `call_metadata/1` expose provider-independent response information.
- `ReqLLM.ToolCall.resolve/3` validates and inspects an application tool call
  without invoking its callback. `execute/3` is an explicit single-tool
  execution boundary when a host chooses to use it.
- `ReqLLM.Context.append_tool_exchange/3` validates and appends an assistant
  tool-call message plus matched tool results. It never executes a tool or
  starts another model interaction.

`response.provider_meta` and the `provider_metadata` returned by
`ReqLLM.Response.call_metadata/1` are provider extensions. They are useful for
observability and provider-specific capabilities, but a portable host should
not depend on their keys for core control flow.

## One buffered interaction

A host adapter can keep one call small and explicit:

```elixir
defmodule MyApp.LLMHost do
  def call_once(model_spec, context, tools, conversation_id) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, response} <-
           ReqLLM.generate_text(model, context,
             tools: tools,
             telemetry: [conversation_id: conversation_id]
           ) do
      {:ok,
       %{
         response: response,
         outcome: ReqLLM.Response.classify(response),
         output_items: ReqLLM.Response.output_items(response),
         usage: ReqLLM.Response.usage(response),
         call: ReqLLM.Response.call_metadata(response)
       }}
    end
  end
end
```

The non-bang APIs preserve `{:ok, value}` and `{:error, reason}` so the host can
handle failures without converting them to exceptions. Bang variants remain
available when exception-based control flow is intentional.

The call performs no follow-up work. If `outcome.type` is `:tool_calls`, the
host decides whether each call is allowed, rejected, deferred, or executed.

Transcription keeps its established compact result by default. A host that
needs call-level observability can opt into the detailed facade without making
a second provider request or changing the nested result:

```elixir
{:ok, detailed} =
  ReqLLM.transcribe_detailed(model, audio,
    telemetry: [conversation_id: conversation_id]
  )

transcript = detailed.result
call = detailed.call_metadata
```

`call` always identifies the resolved model and provider. Usage and cost,
request or response identifiers, warnings, timings, and provider metadata are
present only when observed. The top-level `request_id` is ReqLLM's telemetry
correlation ID; a provider request ID remains under `provider_metadata`.

## Inspect, execute, and continue explicitly

The host can inspect calls before any callback runs:

```elixir
resolutions =
  Enum.map(ReqLLM.Response.tool_calls(response), fn call ->
    ReqLLM.ToolCall.resolve(call, tools)
  end)
```

An application call is executable only when its resolution state is `:valid`.
Unknown or invalid calls, provider-executed builtins, and provider-native calls
remain visible without being treated as application callbacks. The host owns
approval and may call `ReqLLM.ToolCall.execute/3`, invoke its own tool runtime,
or produce an application-defined failure result. Provider-executed builtins
need no local result; a provider-native call still needs an explicit matched
result before its exchange can be appended for continuation.

After execution, build canonical result messages and append the complete
exchange:

```elixir
results = [
  ReqLLM.Context.tool_result("call_1", "lookup", "Documentation found")
]

{:ok, continued_context} =
  ReqLLM.Context.append_tool_exchange(input_context, response, results)
```

Results are matched by tool-call ID and appended in assistant call order. The
helper accepts either the original input context or `response.context`; it does
not duplicate the assistant message when that message is already last.

Tool definitions can contain callback functions and are application runtime
state. Exclude them from durable data and restore the host's current tool
registry before a later call:

```elixir
checkpoint = Jason.encode!(%{continued_context | tools: []})
```

JSON decoding returns ordinary maps, so the host also owns reconstructing and
versioning `%ReqLLM.Context{}`, message, and content-part values at its
persistence boundary. ReqLLM does not provide a checkpoint store or resume a
workflow. A later model interaction is another explicit host action:

```elixir
MyApp.LLMHost.call_once(model, restored_context, tools, conversation_id)
```

## One streaming interaction

`ReqLLM.StreamResponse` has one consumable stream. Choose exactly one view for
each response:

- `stream_response.stream` for legacy `ReqLLM.StreamChunk` values;
- `ReqLLM.StreamResponse.tokens/1` for text only;
- `ReqLLM.StreamResponse.events/1` for canonical tagged events;
- `ReqLLM.StreamResponse.process_stream/2` for real-time callbacks and a final
  materialized `ReqLLM.Response`; or
- `ReqLLM.StreamResponse.to_response/1` when only the final response is needed.

Consuming one view consumes the underlying stream. Do not enumerate events and
then try to materialize the same `StreamResponse`.

For a host that consumes events directly:

```elixir
with {:ok, stream_response} <-
       ReqLLM.stream_text(model, context,
         tools: tools,
         telemetry: [conversation_id: conversation_id]
       ) do
  try do
    stream_response
    |> ReqLLM.StreamResponse.events()
    |> Enum.each(&MyApp.Events.handle/1)
  after
    ReqLLM.StreamResponse.close(stream_response)
  end
end
```

A fully consumed event stream begins with `:start`, preserves output delta
order, emits assembled tool calls, usage, and warnings when available, and ends
with one `:finish`, `:cancelled`, or `:error` event. Always call
`ReqLLM.StreamResponse.close/1` after consuming the raw stream or using
`tokens/1`, `events/1`, `text/1`, `tool_calls/1`, `extract_tool_calls/1`, or
`classify/1`. An `after` block also guarantees cancellation and cleanup when
enumeration stops early or raises. Only `process_stream/2` and `to_response/1`
close their metadata handles before returning.

Buffered responses and fully materialized streams expose the same canonical
information for capabilities supported by both paths. Streaming deltas retain
arrival order and may expose information incrementally before the final values
are known.

## Correlation and errors

ReqLLM assigns one `request_id` to all telemetry events for a model
interaction. Pass `telemetry: [conversation_id: value]` to add the host's
workflow, session, or step correlation. The host should use `conversation_id`
across interactions and treat each ReqLLM `request_id` as one call within that
larger operation.

Provider and validation failures retain ReqLLM's public error tuples and error
structures. Event consumers receive a terminal `:error` event for failures
encountered by the event projection; direct legacy chunk consumption keeps its
existing exception behavior. Cross-call retry policy remains a host decision.

## What this contract does not include

ReqLLM does not schedule another interaction, implement an agent loop, approve
tools, persist memory, checkpoint workflows, delegate tasks, or manage a
sandbox. A concrete Jido adapter belongs in Jido or a separate integration
package and should depend on the public values in this guide rather than
provider modules or wire payloads.

See the [compatibility policy](../COMPATIBILITY.md) for the complete ReqLLM/Jido
ownership boundary and the [telemetry guide](telemetry.md) for event details.
