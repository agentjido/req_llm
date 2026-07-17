# V2 Migration Audit

ReqLLM ships a versioned deprecation ledger and a read-only source audit so an
application can prepare for V2 without changing its V1 behavior. V1 deprecated
APIs continue to work for their documented overlap window.

Run the audit from an application root:

```bash
mix req_llm.migration_audit
mix req_llm.migration_audit lib test
mix req_llm.migration_audit --exclude test/fixtures
mix req_llm.migration_audit --format json
```

The default command recursively scans `.ex` and `.exs` files. It ignores
dependency, build, VCS, coverage, generated documentation, and Node dependency
directories. It parses source but never evaluates or rewrites it, starts ReqLLM,
loads credentials, or makes a provider request.

Exit status `0` means the report is clean or contains advisories only. Status
`1` means actionable migration findings are present.
Status `2` means a requested path could not be read, source could not be parsed,
or the bundled ledger was invalid.

## Machine-readable ledger

[`priv/deprecations.json`](https://github.com/agentjido/req_llm/blob/main/priv/deprecations.json)
is the source of truth. Schema version 1 records the owner, deprecated contract,
replacement, introduction release, target major, V2 scope status, minimum overlap
window, guide, and static detector for every active deprecation. An
`introduced_version` of `unreleased` identifies a deprecation added after the
latest tagged release.

`target_major: 2` identifies the next major in which a removal could be
compatible; it is not approval by itself. Only records with
`v2_scope: "approved"` belong to the breaking scope accepted by the V2
roadmap. An `unapproved` record remains an active deprecation and must not be
removed in V2 without a separate scope decision. The audit reports those
records as non-blocking advisories so they remain visible without expanding the
approved V2 migration plan.

Applications and tooling can inspect the exact shipped data:

```elixir
ledger = ReqLLM.Migration.ledger()
deprecations = ReqLLM.Migration.deprecations()
checks = ReqLLM.Migration.migration_checks()
```

`ReqLLM.Migration.audit/2` returns the same schema-versioned report as the Mix
task. Reports contain source locations and migration guidance, never source
snippets or evaluated values.

Schema version 1 has stable common fields:

```json
{
  "schema_version": 1,
  "status": "findings",
  "summary": {
    "files_scanned": 12,
    "actionable": 1,
    "advisory": 0,
    "errors": 0
  },
  "findings": [
    {
      "id": "req_llm.stream_text_bang",
      "category": "deprecated_api",
      "actionable": true,
      "file": "lib/client.ex",
      "line": 12,
      "column": 5,
      "contract": "ReqLLM.stream_text!/2",
      "owner": "ReqLLM core maintainers",
      "message": "ReqLLM.stream_text!/3 is deprecated.",
      "replacement": "ReqLLM.stream_text/3 and a ReqLLM.StreamResponse projection",
      "guide": "https://hexdocs.pm/req_llm/v2-migration-audit.html#bang-streaming-apis"
    }
  ],
  "errors": []
}
```

Top-level status is `clean`, `advisory`, `findings`, or `error`. Every finding
retains the common fields shown above. Errors contain `file` and `message`.
Additional finding IDs may be added without changing schema version; existing
common fields retain their meaning. Precompile a newly changed project with
`mix compile --quiet` before piping the task's standard output to another
process.

## Bang streaming APIs

The deprecated bang functions return `:ok`; they do not return an enumerable.
Choose the projection needed by the consumer.

Before:

```elixir
ReqLLM.stream_text!(model, prompt)
```

After, for text deltas:

```elixir
{:ok, response} = ReqLLM.stream_text(model, prompt)
Enum.each(ReqLLM.StreamResponse.tokens(response), &IO.write/1)
```

After, for canonical lifecycle and output events:

```elixir
{:ok, response} = ReqLLM.stream_text(model, prompt)
Enum.each(ReqLLM.StreamResponse.events(response), &handle_event/1)
```

The same replacement applies to `ReqLLM.Generation.stream_text!/3`,
`ReqLLM.stream_object!/4`, and `ReqLLM.Generation.stream_object!/4` using their
non-bang counterparts.

## Context tool-call helpers

Before:

```elixir
ReqLLM.Context.assistant_with_tools(tool_calls, "Checking")
ReqLLM.Context.assistant_tool_call("weather", %{city: "Chicago"})
ReqLLM.Context.assistant_tool_calls(calls)
```

After:

```elixir
ReqLLM.Context.assistant("Checking", tool_calls: tool_calls)
ReqLLM.Context.assistant("", tool_calls: [{"weather", %{city: "Chicago"}}])
ReqLLM.Context.assistant("", tool_calls: calls)
```

Preserve any IDs and metadata in the supported `assistant/2` option shape.

## Key lookup aliases

Before:

```elixir
ReqLLM.Keys.fetch(:openai)
ReqLLM.Keys.fetch!(:openai)
```

After:

```elixir
ReqLLM.Keys.get(:openai)
ReqLLM.Keys.get!(:openai)
```

## Tool-call flag helper

Before:

```elixir
ReqLLM.ToolCall.builtin_flag?(value)
```

After:

```elixir
ReqLLM.ToolCall.flagged_builtin?(value)
```

The replacement retains the original flag-only behavior and names it
explicitly.

## Meta Llama delegates

The compatibility delegates on `ReqLLM.Providers.Meta` move to the module that
owns the Llama wire format. For example:

```elixir
ReqLLM.Providers.Meta.format_request(context, options)
ReqLLM.Providers.Meta.Llama.format_request(context, options)
```

Apply the same module move to `format_llama_prompt/1`, `parse_response/2`,
`extract_usage/1`, and `parse_stop_reason/1`.

## Provider option namespaces

The V1 flat shape remains supported. A literal provider model and literal flat
options can be migrated mechanically to the additive provider-keyed shape.

Before:

```elixir
ReqLLM.generate_text("openai:gpt-4o", prompt,
  provider_options: [store: false]
)
```

After:

```elixir
ReqLLM.generate_text("openai:gpt-4o", prompt,
  provider_options: [openai: [store: false]]
)
```

The audit reports this only when the provider identity and option container are
both literal. Hosted providers use the selected ReqLLM provider identity, such
as `azure` or `google_vertex`, as the outer key.

## Raw stream assumptions

`StreamResponse.stream` remains stable throughout V1. V2 may make canonical
events the primary raw stream, so code that explicitly matches the struct field
should choose a named projection now.

Before:

```elixir
%ReqLLM.StreamResponse{stream: chunks} = response
Enum.each(chunks, &handle_chunk/1)
```

After:

```elixir
response
|> ReqLLM.StreamResponse.events()
|> Enum.each(&handle_event/1)
```

Use `tokens/1`, `tool_calls/1`, or another documented projection when those
semantics are the real dependency. The audit detects explicit struct field
matching; it does not infer the type of an arbitrary `value.stream` expression.

## Provider extension inventory

Direct `use ReqLLM.Provider` and `@behaviour ReqLLM.Provider` declarations are
reported as advisories. The provider behavior remains stable in V1 and the V2
replacement is not frozen. There is no code migration to perform yet.

Keep the existing provider conformance suite green, record the extension in the
V2 ecosystem survey, and follow the
[provider extension decision](provider-extension-decision.md). Advisory-only
reports exit successfully.

## Structured-output validation default

V1 preserves compatible validation. V2 may make strict final validation the
default. Set the intended policy explicitly on statically structured calls.

Before:

```elixir
ReqLLM.generate_text(model, prompt,
  output: ReqLLM.Output.object(name: [type: :string])
)
```

After, preserving V1 behavior:

```elixir
ReqLLM.generate_text(model, prompt,
  output: ReqLLM.Output.object(name: [type: :string]),
  output_validation: :compatible
)
```

After, opting into the proposed V2 safety default now:

```elixir
ReqLLM.generate_text(model, prompt,
  output: ReqLLM.Output.object(name: [type: :string]),
  output_validation: :strict
)
```

The check also covers literal `generate_object` and streaming object calls when
their option source is statically visible.

## Limitations and false positives

The audit deliberately avoids general Elixir data-flow analysis. It detects
fully qualified remote calls, literal model and option shapes, explicit
`ReqLLM.StreamResponse` struct matching, and direct fully qualified provider
behavior declarations.

It does not resolve imported functions, local aliases, macro-generated calls,
computed model specifications, variable option containers, or the runtime type
of field access. These cases require manual review. A computed value is not
reported merely because it could contain a legacy shape.

Comments and strings are ignored because the audit parses syntax. A source file
that cannot be parsed is an error rather than a partial success. Findings are
deterministically ordered by file and source location, making JSON output stable
for CI and editor integrations.
