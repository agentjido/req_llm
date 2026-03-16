# Azure

Access AI models through Microsoft Azure's enterprise cloud platform. Supports OpenAI models (GPT-4, GPT-4o, o1, o3 series) and Anthropic Claude models with full tool calling and streaming support.

## Configuration

Azure uses API key authentication with deployment-based routing.

### Environment Variables

```bash
AZURE_OPENAI_API_KEY=your-api-key
```

### Provider Options

```elixir
ReqLLM.generate_text(
  "azure:gpt-4o",
  "Hello",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-gpt4-deployment"
)
```

## Model Specs

For the full model-spec workflow, see [Model Specs](model-specs.md).

Azure is a strong fit for the full explicit model specification path because `base_url` is part of the model metadata. Use exact Azure model IDs from [LLMDB.xyz](https://llmdb.xyz) when possible, and use `ReqLLM.model!/1` when you need to pin `base_url` or work ahead of the registry. `deployment` remains a request option.

## Key Differences from Direct Provider APIs

1. **Custom endpoints**: Each Azure resource has a unique base URL
   (`https://{resource}.openai.azure.com/openai`)

2. **Deployment-based routing**: Models are accessed via deployments, not model names.
   - OpenAI: `/deployments/{deployment}/chat/completions?api-version={version}`
   - Anthropic: `/v1/messages` (model specified in body, like native Anthropic API)

3. **API key authentication**: Uses `api-key` header for all model families

4. **No model field in body**: The deployment ID in the URL determines the model

## Provider Options

Passed via `:provider_options` keyword or as top-level options:

### `base_url` (Required)

- **Type**: String
- **Purpose**: Azure resource endpoint
- **Format**: `https://{resource-name}.openai.azure.com/openai`
- **Example**: `base_url: "https://my-company.openai.azure.com/openai"`
- **Note**: Must be customized for your Azure resource

### `deployment`

- **Type**: String
- **Default**: Uses `model.id` (e.g., `gpt-4o`)
- **Purpose**: Azure deployment name that determines which model is used
- **Example**: `deployment: "my-gpt4-deployment"`
- **Note**: The deployment name is configured when you deploy a model in Azure

### `api_version`

- **Type**: String
- **Default**: `"2025-04-01-preview"`
- **Purpose**: Azure API version
- **Example**: `provider_options: [api_version: "2024-10-01-preview"]`
- **Note**: Check Azure documentation for supported versions

### `api_key`

- **Type**: String
- **Purpose**: Azure API key
- **Fallback**: `AZURE_OPENAI_API_KEY` env var
- **Example**: `api_key: "your-api-key"`

## Examples

### Basic Usage (OpenAI)

```elixir
{:ok, response} = ReqLLM.generate_text(
  "azure:gpt-4o",
  "What is Elixir?",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-gpt4-deployment"
)
```

### Basic Usage (Anthropic Claude)

```elixir
{:ok, response} = ReqLLM.generate_text(
  "azure:claude-3-sonnet",
  "What is Elixir?",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-claude-deployment"
)
```

### Streaming

```elixir
{:ok, response} = ReqLLM.stream_text(
  "azure:gpt-4o",
  "Tell me a story",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-gpt4-deployment"
)

ReqLLM.StreamResponse.tokens(response)
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### Tool Calling

```elixir
tools = [
  ReqLLM.tool(
    name: "get_weather",
    description: "Get weather for a location",
    parameter_schema: [location: [type: :string, required: true]],
    callback: &MyApp.Weather.fetch/1
  )
]

{:ok, response} = ReqLLM.generate_text(
  "azure:gpt-4o",
  "What's the weather in Paris?",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-gpt4-deployment",
  tools: tools
)
```

### Embeddings

```elixir
{:ok, embedding} = ReqLLM.generate_embedding(
  "azure:text-embedding-3-small",
  "Hello world",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-embedding-deployment"
)
```

### Structured Output

```elixir
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true]
]

{:ok, person} = ReqLLM.generate_object(
  "azure:gpt-4o",
  "Generate a fictional person",
  schema,
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-gpt4-deployment"
)
```

### Extended Thinking (Claude)

```elixir
{:ok, response} = ReqLLM.generate_text(
  "azure:claude-3-sonnet",
  "Solve this complex problem step by step",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-claude-deployment",
  reasoning_effort: :medium
)
```

## Supported Models

### OpenAI GPT-4 Family

- `azure:gpt-4o` - Latest multimodal model
- `azure:gpt-4o-mini` - Smaller, faster variant
- `azure:gpt-4` - Original GPT-4
- `azure:gpt-4-turbo` - Faster GPT-4 variant

### OpenAI Reasoning Models

- `azure:o1` - Advanced reasoning model
- `azure:o1-mini` - Smaller reasoning model
- `azure:o3` - Latest reasoning model
- `azure:o3-mini` - Smaller o3 variant

**Note**: Reasoning models use `max_completion_tokens` instead of `max_tokens`. ReqLLM handles this translation automatically.

### OpenAI Embedding Models

- `azure:text-embedding-3-small` - Small, efficient embeddings
- `azure:text-embedding-3-large` - Higher quality embeddings
- `azure:text-embedding-ada-002` - Legacy embedding model

### Anthropic Claude Models

- `azure:claude-3-opus` - Most capable Claude model
- `azure:claude-3-sonnet` - Balanced performance
- `azure:claude-3-haiku` - Fast, efficient model
- `azure:claude-3-5-sonnet` - Latest Claude 3.5 Sonnet

**Note**: Claude models support extended thinking via `reasoning_effort` option.

## Wire Format Notes

### OpenAI Models
- **Endpoint**: `/deployments/{deployment}/chat/completions`
- **API**: OpenAI Chat Completions format (model field omitted)

### Anthropic Models
- **Endpoint**: `/v1/messages` (model specified in request body)
- **API**: Anthropic Messages format
- **Headers**: Includes `anthropic-version: 2023-06-01` and `x-api-key`

### Common
- **Authentication**: `api-key` header for all model families
- **Streaming**: Standard Server-Sent Events (SSE)
- **API Version**: Required query parameter on all requests

All differences handled automatically by ReqLLM.

## Error Handling

Common error scenarios:

- **Missing API key**: Set `AZURE_OPENAI_API_KEY` or pass `api_key` option
- **Invalid deployment**: Ensure the deployment name matches your Azure resource
- **Placeholder base_url**: Must provide your actual resource URL
- **Unsupported API version**: Check Azure documentation for supported versions

## Resources

- [Azure OpenAI Service Documentation](https://learn.microsoft.com/en-us/azure/ai-services/openai/)
- [Azure OpenAI REST API Reference](https://learn.microsoft.com/en-us/azure/ai-services/openai/reference)
- [Quickstart: Get started with Azure OpenAI](https://learn.microsoft.com/en-us/azure/ai-services/openai/quickstart)
