# Amazon Bedrock

Access AWS Bedrock's unified API for multiple AI model families including Anthropic Claude, Meta Llama, Amazon Nova, and Cohere.

## Configuration

AWS Bedrock uses AWS Signature V4 authentication. Configure credentials via:

### Option 1: Environment Variables (Recommended)
```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
```

### Option 2: ReqLLM Keys (Composite Key)
```elixir
ReqLLM.put_key(:aws_bedrock, %{
  access_key_id: "AKIA...",
  secret_access_key: "...",
  region: "us-east-1"
})
```

### Option 3: Provider Options
```elixir
ReqLLM.generate_text(
  "bedrock:anthropic.claude-3-sonnet-20240229-v1:0",
  "Hello",
  provider_options: [
    region: "us-east-1",
    access_key_id: "AKIA...",
    secret_access_key: "..."
  ]
)
```

## Provider Options

Passed via `:provider_options` keyword:

### `region`
- **Type**: String
- **Default**: `"us-east-1"`
- **Purpose**: AWS region where Bedrock is available
- **Example**: `provider_options: [region: "us-west-2"]`

### `access_key_id`
- **Type**: String
- **Purpose**: AWS Access Key ID
- **Fallback**: `AWS_ACCESS_KEY_ID` env var
- **Example**: `provider_options: [access_key_id: "AKIA..."]`

### `secret_access_key`
- **Type**: String
- **Purpose**: AWS Secret Access Key
- **Fallback**: `AWS_SECRET_ACCESS_KEY` env var
- **Example**: `provider_options: [secret_access_key: "..."]`

### `session_token`
- **Type**: String
- **Purpose**: AWS Session Token for temporary credentials
- **Example**: `provider_options: [session_token: "..."]`

### `use_converse`
- **Type**: Boolean
- **Purpose**: Force use of Bedrock Converse API
- **Default**: Auto-detect based on tools presence
- **Example**: `provider_options: [use_converse: true]`

### `additional_model_request_fields`
- **Type**: Map
- **Purpose**: Additional model-specific request fields
- **Example**: `provider_options: [additional_model_request_fields: %{reasoning_config: %{...}}]`
- **Use Case**: Claude extended thinking configuration

### Claude-Specific Options

#### `anthropic_prompt_cache`
- **Type**: Boolean
- **Purpose**: Enable Anthropic prompt caching for Claude models
- **Example**: `provider_options: [anthropic_prompt_cache: true]`

#### `anthropic_prompt_cache_ttl`
- **Type**: String (e.g., `"1h"`)
- **Purpose**: Cache TTL (default ~5min if omitted)
- **Example**: `provider_options: [anthropic_prompt_cache_ttl: "1h"]`

## Supported Model Families

- **Anthropic Claude**: Fully implemented
- **Meta Llama**: Extensible support
- **Amazon Nova**: Extensible support
- **Cohere**: Extensible support

## Extending for New Models

To add support for a new model family:

1. Add model family to provider's model families
2. Implement format functions:
   - `format_request/3` - Convert ReqLLM context to provider format
   - `parse_response/2` - Convert provider response to ReqLLM format
   - `parse_stream_chunk/2` - Handle streaming responses

See provider implementation for details.

## Resources

- [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/)
- [Bedrock Runtime API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Welcome.html)
