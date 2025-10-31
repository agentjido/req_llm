# Z.AI Coder

OpenAI-compatible API for Z.AI GLM models (Coding Endpoint).

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

This provider uses Z.AI's **coding endpoint** (`/api/coding/paas/v4`) optimized for:
- Code generation
- Technical tasks
- Programming assistance

For general-purpose chat and reasoning, use the [Z.AI Provider](zai.md).

## Implementation Notes

- Extended timeout for thinking mode (300s)
- Full OpenAI compatibility
- Automatic thinking mode detection and timeout adjustment
- Optimized for code-related prompts

## Resources

- [Z.AI Documentation](https://z.ai/docs)
