# Meta (Llama)

Generic provider for Meta Llama models using Meta's native prompt format.

## Important Usage Note

**Most deployments use OpenAI-compatible APIs** and should NOT use this provider directly:

- Azure AI Foundry → Use OpenAI-compatible API
- Google Cloud Vertex AI → Use OpenAI-compatible API
- vLLM (self-hosted) → Use OpenAI-compatible API
- Ollama (self-hosted) → Use OpenAI-compatible API
- llama.cpp (self-hosted) → Use OpenAI-compatible API

This provider is for services using **Meta's native format** with `prompt`, `max_gen_len`, `generation` fields.

## Current Use Cases

- **AWS Bedrock**: Uses native Meta format via `ReqLLM.Providers.AmazonBedrock.Meta`

For AWS Bedrock, see [Amazon Bedrock Provider Guide](amazon_bedrock.md).

## Configuration

No direct configuration - wrapped by cloud providers using native format.

## Native Format Details

### Request Format
- `prompt` - Formatted text with Llama special tokens
- `max_gen_len` - Maximum tokens to generate
- `temperature` - Sampling temperature
- `top_p` - Nucleus sampling parameter

### Response Format
- `generation` - Generated text
- `prompt_token_count` - Input token count
- `generation_token_count` - Output token count
- `stop_reason` - Why generation stopped

### Llama Prompt Format

Llama 3+ uses structured prompt format with special tokens:
- System: `<|start_header_id|>system<|end_header_id|>`
- User: `<|start_header_id|>user<|end_header_id|>`
- Assistant: `<|start_header_id|>assistant<|end_header_id|>`

## Provider Options

No custom provider options - uses standard ReqLLM options translated to native format.

## Resources

- [Meta Llama Documentation](https://llama.meta.com/)
- [Llama Model Cards](https://github.com/meta-llama/llama-models)
