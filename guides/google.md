# Google (Gemini)

Access Gemini models with built-in web grounding and thinking capabilities.

## Configuration

```bash
GOOGLE_API_KEY=AIza...
```

## Provider Options

Passed via `:provider_options` keyword:

### `google_api_version`
- **Type**: `"v1"` | `"v1beta"`
- **Default**: `"v1"`
- **Purpose**: Select API version (v1beta required for grounding)
- **Example**: `provider_options: [google_api_version: "v1beta"]`
- **Note**: Auto-set to v1beta when `google_grounding` is used

### `google_grounding`
- **Type**: Map
- **Purpose**: Enable Google Search grounding (requires v1beta)
- **Modern (Gemini 2.5)**: `%{enable: true}`
- **Legacy (Gemini 1.5)**: `%{dynamic_retrieval: %{mode: "MODE_DYNAMIC", dynamic_threshold: 0.7}}`
- **Example**: `provider_options: [google_grounding: %{enable: true}]`

### `google_thinking_budget`
- **Type**: Non-negative integer
- **Purpose**: Control thinking tokens for Gemini 2.5 models
- **`0`**: Disable thinking
- **Omit**: Dynamic allocation (default)
- **Example**: `provider_options: [google_thinking_budget: 4096]`

### `google_safety_settings`
- **Type**: List of maps
- **Purpose**: Configure content safety filters
- **Categories**: `HARM_CATEGORY_HATE_SPEECH`, `HARM_CATEGORY_DANGEROUS_CONTENT`, `HARM_CATEGORY_HARASSMENT`, `HARM_CATEGORY_SEXUALLY_EXPLICIT`
- **Thresholds**: `BLOCK_NONE`, `BLOCK_ONLY_HIGH`, `BLOCK_MEDIUM_AND_ABOVE`, `BLOCK_LOW_AND_ABOVE`
- **Example**:
  ```elixir
  provider_options: [
    google_safety_settings: [
      %{category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
    ]
  ]
  ```

### `google_candidate_count`
- **Type**: Positive integer
- **Default**: `1`
- **Purpose**: Generate multiple candidates (only first returned)
- **Example**: `provider_options: [google_candidate_count: 3]`

### Embedding Options

#### `dimensions`
- **Type**: `128..3072`
- **Purpose**: Control embedding vector dimensions
- **Recommended**: `768`, `1536`, or `3072`
- **Example**: `provider_options: [dimensions: 768]`

#### `task_type`
- **Type**: String
- **Purpose**: Specify embedding task type
- **Values**: `RETRIEVAL_QUERY`, `RETRIEVAL_DOCUMENT`, `SEMANTIC_SIMILARITY`, `CLASSIFICATION`
- **Example**: `provider_options: [task_type: "RETRIEVAL_QUERY"]`

#### `title`
- **Type**: String
- **Purpose**: Document title for better embedding quality
- **Example**: `provider_options: [title: "Product Documentation", task_type: "RETRIEVAL_DOCUMENT"]`

## Wire Format Notes

- Endpoint: `/models/{model}:generateContent`
- Auth: API key in query param or header
- System: Separate `systemInstruction` field
- Safety: Gemini-specific safety configuration

All differences handled automatically by ReqLLM.

## Resources

- [Google AI Documentation](https://ai.google.dev/docs)
- [Gemini API Reference](https://ai.google.dev/api/rest)
