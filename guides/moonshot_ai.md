# Moonshot AI

Use Kimi models through Moonshot AI's OpenAI-compatible Chat Completions API.

## Configuration

```bash
MOONSHOT_API_KEY=your-api-key
```

Or configure the key programmatically:

```elixir
ReqLLM.put_key(:moonshotai_api_key, "your-api-key")
```

## Kimi K3

Kimi K3 is an always-reasoning multimodal model. Generate text or stream a response with the
standard ReqLLM APIs:

```elixir
{:ok, response} =
  ReqLLM.generate_text(
    "moonshotai:kimi-k3",
    "Explain why linear attention is useful.",
    reasoning_effort: :max,
    max_completion_tokens: 4096
  )

ReqLLM.stream_text("moonshotai:kimi-k3", "Explain the same idea with an analogy")
|> Stream.each(&IO.write/1)
|> Stream.run()
```

K3 currently supports only maximum reasoning effort. ReqLLM sends `reasoning_effort: "max"`
and translates lower canonical effort values to max with a warning. K3 does not use the K2.x
`thinking` option.

K3 fixes `temperature`, `top_p`, `n`, `presence_penalty`, and `frequency_penalty`. ReqLLM omits
those fields even when generic option bundles supply them. `max_tokens` is translated to
`max_completion_tokens`.

Because max-effort reasoning can take longer than ordinary chat completion, the provider uses a
five-minute receive timeout by default. Pass `receive_timeout` explicitly to override it.

## Reasoning and tool calls

Moonshot returns reasoning in `reasoning_content` separately from final content. ReqLLM
normalizes it into thinking content for both regular and streaming responses, then restores
`reasoning_content` when an assistant message is sent back in a multi-turn or tool-call request.

Standard ReqLLM tools, `tool_choice: "required"`, strict JSON Schema output, and base64 image
inputs use the shared OpenAI-compatible request shapes. K3 cannot combine always-on reasoning with
a specifically named tool choice, so ReqLLM translates named choices to `"required"` while keeping
the tool definitions intact.

## Resources

- [Kimi K3 quickstart](https://platform.kimi.ai/docs/guide/kimi-k3-quickstart)
- [Chat Completions API](https://platform.kimi.ai/docs/api/chat)
- [Model parameter reference](https://platform.kimi.ai/docs/api/models-overview)
