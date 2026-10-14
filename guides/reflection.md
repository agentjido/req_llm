# Reflection AI

Use Reflection for text, reasoning, tool calls, and JSON output. The provider
uses `https://api.reflection.ai/openai/v1/chat/completions`.

## Configuration

Set the key in your application's environment or `.env` file:

```bash
REFLECTION_API_KEY=your-api-key
```

You can also use `ReqLLM.put_key(:reflection_api_key, "your-api-key")` or pass
`api_key: "your-api-key"` on a request.

## Model and text requests

Use an explicit model spec until the installed LLMDB release includes Reflection.
This spec works without a catalog entry:

```elixir
model = ReqLLM.model!(%{provider: :reflection, id: "Beam-1.0-501B-A23B"})

{:ok, response} =
  ReqLLM.generate_text(model, "Explain linear attention.",
    reasoning_effort: :low,
    max_tokens: 4096
  )

ReqLLM.Response.text(response)
```

The string `"reflection:Beam-1.0-501B-A23B"` also works. ReqLLM gives an
unverified-model warning when the installed catalog does not contain the model.
The catalog data was added in [LLMDB PR #360](https://github.com/agentjido/llmdb/pull/360).

Beam always reasons. Set `reasoning_effort` to `:low`, `:medium`, `:high`,
`:xhigh`, or `:max`. Omit it, or use `:default`, to use your organization's
default effort. `:none` and `:minimal` return a validation error.

`max_tokens` becomes `max_completion_tokens` on the wire. This limit includes
reasoning and answer tokens. If you supply both limits, `max_completion_tokens`
takes precedence. Non-streaming requests use a five-minute receive timeout.
Set `receive_timeout` to change the timeout for a request or stream.

## Streams and conversation history

```elixir
{:ok, stream} = ReqLLM.stream_text(model, "What is 2 + 4?", reasoning_effort: :low)
{:ok, response} = ReqLLM.StreamResponse.to_response(stream)

context = ReqLLM.Context.append(response.context, ReqLLM.Context.user("Add 1."))
{:ok, next_response} = ReqLLM.generate_text(model, context, reasoning_effort: :low)
```

Reflection requires non-empty `reasoning_content` on every previous assistant
message. ReqLLM stores it in thinking content parts and sends it back on the
next request. Reuse `response.context` to preserve reasoning. A manually built
assistant message without reasoning returns a validation error before the request.

## Tools and JSON output

Use standard `ReqLLM.Tool` definitions and `tool_choice`. Named tool choice,
strict tools, and `parallel_tool_calls` are supported. ReqLLM sends
`parallel_tool_calls` only when tools are present. After a tool call, append the
tool result to `response.context` to preserve the assistant's reasoning.

```elixir
ReqLLM.generate_object(model, "Return greeting set to hello.",
  [greeting: [type: :string, required: true]],
  reasoning_effort: :low,
  max_tokens: 4096
)
```

`generate_object` and `stream_object` use native JSON schema output. For JSON
mode, pass `provider_options: [response_format: %{type: "json_object"}]` and ask
for JSON in the prompt. You can also supply a JSON schema response format with
`strict: true`. Strict tools and schemas must meet Reflection's schema rules.

## Limits

Input is text only. Embeddings, image generation, speech, and transcription are
not supported. ReqLLM removes `top_k`, `reasoning_token_budget`, `stop`, and
`seed` with a warning because Reflection does not apply these controls. Use
`on_unsupported: :error` to return an error instead.

## References

- [API compatibility](https://developers.reflection.ai/openai-compatibility)
- [Reasoning](https://developers.reflection.ai/reasoning)
- [Tool calling](https://developers.reflection.ai/tool-calling)
- [Structured output and strict schema rules](https://developers.reflection.ai/structured-outputs)
