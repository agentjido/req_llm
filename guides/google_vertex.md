# Google Vertex AI

Access Claude models through Google Cloud's Vertex AI platform. All Claude 4.x models including Opus, Sonnet, and Haiku with full tool calling and reasoning support.

## Configuration

Vertex AI uses Google Cloud OAuth2 authentication with service accounts.

### Service Account (Recommended)

**Environment Variables:**

```bash
GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
GOOGLE_CLOUD_PROJECT="your-project-id"
GOOGLE_CLOUD_REGION="global"
```

**Provider Options:**

```elixir
ReqLLM.generate_text(
  "google_vertex_anthropic:claude-sonnet-4-5@20250929",
  "Hello",
  provider_options: [
    service_account_json: "/path/to/service-account.json",
    project_id: "your-project-id",
    region: "global"
  ]
)
```

## Provider Options

Passed via `:provider_options` keyword:

### `service_account_json`

- **Type**: String (file path)
- **Purpose**: Path to Google Cloud service account JSON file
- **Fallback**: `GOOGLE_APPLICATION_CREDENTIALS` env var
- **Example**: `provider_options: [service_account_json: "/path/to/credentials.json"]`

### `access_token`

- **Type**: String
- **Purpose**: Use an existing OAuth2 access token generated outside ReqLLM (e.g., via Goth or gcloud)
- **Behavior**: Bypasses the service account JSON flow and internal token management
- **Example**: `provider_options: [access_token: "your-access-token"]`

### `project_id`

- **Type**: String
- **Purpose**: Google Cloud project ID
- **Fallback**: `GOOGLE_CLOUD_PROJECT` env var
- **Example**: `provider_options: [project_id: "my-project-123"]`
- **Required**: Yes

### `region`

- **Type**: String
- **Default**: `"global"`
- **Purpose**: GCP region for Vertex AI endpoint
- **Example**: `provider_options: [region: "us-central1"]`
- **Note**: Use `"global"` for newest models, specific regions for regional deployment

### `additional_model_request_fields`

- **Type**: Map
- **Purpose**: Model-specific request fields (e.g., thinking configuration)
- **Example**:
  ```elixir
  provider_options: [
    additional_model_request_fields: %{
      thinking: %{type: "enabled", budget_tokens: 4096}
    }
  ]
  ```

### Claude-Specific Options

Vertex AI supports the same Claude options as native Anthropic:

#### `anthropic_top_k`

- **Type**: `1..40`
- **Purpose**: Sample from top K options per token
- **Example**: `provider_options: [anthropic_top_k: 20]`

#### `stop_sequences`

- **Type**: List of strings
- **Purpose**: Custom stop sequences
- **Example**: `provider_options: [stop_sequences: ["END", "STOP"]]`

#### `anthropic_metadata`

- **Type**: Map
- **Purpose**: Request metadata for tracking
- **Example**: `provider_options: [anthropic_metadata: %{user_id: "123"}]`

#### `thinking`

- **Type**: Map
- **Purpose**: Enable extended thinking/reasoning
- **Example**: `provider_options: [thinking: %{type: "enabled", budget_tokens: 4096}]`
- **Access**: `ReqLLM.Response.thinking(response)`

#### `anthropic_prompt_cache`

- **Type**: Boolean
- **Purpose**: Enable prompt caching
- **Example**: `provider_options: [anthropic_prompt_cache: true]`

#### `anthropic_prompt_cache_ttl`

- **Type**: String (e.g., `"1h"`)
- **Purpose**: Cache TTL (default ~5min if omitted)
- **Example**: `provider_options: [anthropic_prompt_cache_ttl: "1h"]`

## Supported Models

### Claude 4.5 Family

- **Haiku 4.5**: `google_vertex_anthropic:claude-haiku-4-5@20251001`
  - Fast, cost-effective
  - Full tool calling and reasoning support

- **Sonnet 4.5**: `google_vertex_anthropic:claude-sonnet-4-5@20250929`
  - Balanced performance and capability
  - Extended thinking support

- **Opus 4.1**: `google_vertex_anthropic:claude-opus-4-1@20250805`
  - Highest capability
  - Advanced reasoning

### Claude 4.0 & Earlier

- **Sonnet 4.0**: `google_vertex_anthropic:claude-sonnet-4@20250514`
- **Opus 4.0**: `google_vertex_anthropic:claude-opus-4@20250514`
- **Sonnet 3.7**: `google_vertex_anthropic:claude-3-7-sonnet@20250219`
- **Sonnet 3.5 v2**: `google_vertex_anthropic:claude-3-5-sonnet@20241022`
- **Haiku 3.5**: `google_vertex_anthropic:claude-3-5-haiku@20241022`

### Model ID Format

Vertex uses the `@` symbol for versioning:

- Format: `claude-{tier}-{version}@{date}`
- Example: `claude-sonnet-4-5@20250929`

## Wire Format Notes

- **Authentication**: OAuth2 with service account tokens (auto-refreshed)
- **Endpoint**: Model-specific paths under `aiplatform.googleapis.com`
- **API**: Uses Anthropic's raw message format (compatible with native API)
- **Streaming**: Standard Server-Sent Events (SSE)
- **Region routing**: Global endpoint for newest models, regional for specific deployments

All differences handled automatically by ReqLLM.

## Resources

- [Vertex AI Documentation](https://cloud.google.com/vertex-ai/docs)
- [Claude on Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/use-claude)
- [Service Account Setup](https://cloud.google.com/iam/docs/service-accounts-create)
