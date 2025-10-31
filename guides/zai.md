# Z.AI

OpenAI-compatible API for Z.AI GLM models (Standard Endpoint).

## Configuration

```bash
ZAI_API_KEY=your-api-key
```

## Provider Options

No custom provider options - uses OpenAI-compatible defaults.

Passed via standard ReqLLM options:
- `temperature`, `max_tokens`, `top_p`
- `tools` for function calling
- Standard context and streaming

## Supported Models

- **glm-4.5** - Advanced reasoning model with 131K context
- **glm-4.5-air** - Lighter variant with same capabilities
- **glm-4.5-flash** - Free tier model with fast inference
- **glm-4.5v** - Vision model supporting text, image, and video inputs
- **glm-4.6** - Latest model with 204K context and improved reasoning

## Standard vs Coder Endpoints

This provider uses Z.AI's **standard endpoint** (`/api/paas/v4`) for general-purpose chat and reasoning tasks.

For code generation optimized responses, use the [Z.AI Coder Provider](zai_coder.md).

## Implementation Notes

- Extended timeout for thinking mode (300s)
- Full OpenAI compatibility
- Automatic thinking mode detection and timeout adjustment

## Resources

- [Z.AI Documentation](https://z.ai/docs)
