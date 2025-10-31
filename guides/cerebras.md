# Cerebras

Ultra-fast inference with OpenAI-compatible API and Cerebras-specific optimizations.

## Configuration

```bash
CEREBRAS_API_KEY=csk_...
```

## Provider Options

No custom provider options - uses OpenAI-compatible defaults with Cerebras-specific handling.

Passed via standard ReqLLM options:
- `temperature`, `max_tokens`, `top_p`
- `tools` (with automatic `strict: true` for non-Qwen models)
- `tool_choice` (`"auto"` or `"none"` only)

## Implementation Notes

### System Messages
System messages have stronger influence compared to OpenAI's implementation.

### Tool Calling
- Requires `strict: true` in tool schemas (automatically added)
- Qwen models do NOT support `strict: true` (automatically excluded)
- Only supports `tool_choice: "auto"` or `"none"` (not function-specific)

### Streaming Limitations
Streaming not supported with:
- Reasoning models in JSON mode
- Tool calling scenarios

### Unsupported OpenAI Features

These fields will result in a 400 error:
- `frequency_penalty`
- `logit_bias`
- `presence_penalty`
- `parallel_tool_calls`
- `service_tier`

All restrictions handled automatically by ReqLLM.

## Resources

- [Cerebras Documentation](https://docs.cerebras.ai/)
